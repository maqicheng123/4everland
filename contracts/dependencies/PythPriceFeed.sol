// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/Address.sol";
import "../interfaces/IPyth.sol";
import "../dependencies/LandOwnable.sol";
import "../dependencies/console.sol";

contract PythPriceFeed is LandOwnable {
	struct OracleRecord {
		IPyth pyth;
		uint32 decimals;
		uint32 heartbeat;
	}

	struct PriceRecord {
		uint96 scaledPrice;
		uint32 timestamp;
		uint32 lastUpdated;
	}

	struct FeedResponse {
		int64 price;
		// Confidence interval around the price
		uint64 conf;
		// Price exponent
		int32 expo;
		// Unix timestamp describing when the price was published
		uint publishTime;
		bool success;
	}

	// Custom Errors --------------------------------------------------------------------------------------------------

	error PriceFeed__InvalidFeedResponseError(address token);
	error PriceFeed__FeedFrozenError(address token);
	error PriceFeed__HeartbeatOutOfBoundsError();

	// Events ---------------------------------------------------------------------------------------------------------

	event NewOracleRegistered(address token, address pyth);
	event PriceFeedStatusUpdated(address token, address oracle, bool isWorking);
	event PriceRecordUpdated(address indexed token, uint256 _price);

	/** Constants ---------------------------------------------------------------------------------------------------- */

	uint256 public constant TARGET_DIGITS = 18;

	// Responses are considered stale this many seconds after the oracle's heartbeat
	uint256 public constant RESPONSE_TIMEOUT_BUFFER = 0 hours;

	bytes32 public constant ETHUSDFEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

	// State ------------------------------------------------------------------------------------------------------------
	mapping(address => OracleRecord) public oracleRecords;
	mapping(address => PriceRecord) public priceRecords;

	constructor(ILandCore _core) LandOwnable(_core) {}

	// Admin routines ---------------------------------------------------------------------------------------------------

	/**
        @notice Set the oracle for a specific token
        @param _token Address of the LST to set the oracle for
        @param _pyth Address of the pyth oracle for this LST
        @param _heartbeat Oracle heartbeat, in seconds
     */
	function setOracle(address _token, address _pyth, uint32 _heartbeat) public onlyOwner {
		if (_heartbeat > 86400) revert PriceFeed__HeartbeatOutOfBoundsError();
		IPyth newFeed = IPyth(_pyth);
		FeedResponse memory currResponse = _fetchFeedResponses(newFeed);
		OracleRecord memory record = OracleRecord({ pyth: newFeed, decimals: uint32(-currResponse.expo), heartbeat: _heartbeat});
		oracleRecords[_token] = record;

		_processFeedResponses(_token, record, currResponse);
		emit NewOracleRegistered(_token, _pyth);
	}

	/**
        @notice Get the latest price returned from the oracle
        @dev You can obtain these values by calling `TroveManager.fetchPrice()`
             rather than directly interacting with this contract.
        @param _token Token to fetch the price for
        @return The latest valid price for the requested token
     */
	function fetchPrice(address _token) public returns (uint256) {
		PriceRecord memory priceRecord = priceRecords[_token];
		if (priceRecord.lastUpdated == block.timestamp) {
			// We short-circuit only if the price was already correct in the current block
			return priceRecord.scaledPrice;
		}

		OracleRecord storage oracle = oracleRecords[_token];
		FeedResponse memory currResponse = _fetchFeedResponses(oracle.pyth);
		return _processFeedResponses(_token, oracle, currResponse);
	}

	// Internal functions -----------------------------------------------------------------------------------------------

	function _processFeedResponses(address _token, OracleRecord memory oracle, FeedResponse memory _currResponse) internal returns (uint256) {
		if (!_isFeedWorking(_currResponse)) {
			revert PriceFeed__InvalidFeedResponseError(_token);
		}
		if (_isPriceStale(_currResponse.publishTime, oracle.heartbeat)) {
			revert PriceFeed__FeedFrozenError(_token);
		}
		uint32 decimals = oracle.decimals;
		uint256 scaledPrice = _scalePriceByDigits(_currResponse.price, decimals);
		_storePrice(_token, scaledPrice, _currResponse.publishTime);
		return scaledPrice;
	}

	function _fetchFeedResponses(IPyth oracle) internal view returns (FeedResponse memory currResponse) {
		currResponse = _fetchCurrentFeedResponse(oracle);
	}

	function _isPriceStale(uint256 _priceTimestamp, uint256 _heartbeat) internal view returns (bool) {
		return block.timestamp - _priceTimestamp > _heartbeat + RESPONSE_TIMEOUT_BUFFER;
	}

	function _isFeedWorking(FeedResponse memory _currentResponse) internal view returns (bool) {
		return _isValidResponse(_currentResponse);
	}

	function _isValidResponse(FeedResponse memory _response) internal view returns (bool) {
		return (_response.success) && (_response.publishTime > 0) && (_response.publishTime <= block.timestamp) && (_response.price > 0);
	}

	function _scalePriceByDigits(int64 _price, uint256 _answerDigits) internal pure returns (uint256) {
		if (_answerDigits == TARGET_DIGITS) {
			return uint256(uint64(_price));
		} else if (_answerDigits < TARGET_DIGITS) {
			// Scale the returned price value up to target precision
			return uint256(uint64(_price)) * (10 ** (TARGET_DIGITS - _answerDigits));
		} else {
			// Scale the returned price value down to target precision
			return uint256(uint64(_price)) / (10 ** (_answerDigits - TARGET_DIGITS));
		}
	}

	function _storePrice(address _token, uint256 _price, uint256 _timestamp) internal {
		priceRecords[_token] = PriceRecord({ scaledPrice: uint96(_price), timestamp: uint32(_timestamp), lastUpdated: uint32(block.timestamp) });
		emit PriceRecordUpdated(_token, _price);
	}

	function _fetchCurrentFeedResponse(IPyth _priceAggregator) internal view returns (FeedResponse memory response) {
		try _priceAggregator.getPriceUnsafe(ETHUSDFEED) returns (IPyth.Price memory price) {
			response.price = price.price;
			response.conf = price.conf;
			response.expo = price.expo;
			response.publishTime = price.publishTime;
			response.success = true;
		} catch {
			return response;
		}
	}
}
