// SPDX-License-Identifier: MIT
/* solhint-disable not-rely-on-time */
pragma solidity 0.7.3;

import {
    IInstantDistributionAgreementV1,
    ISuperfluidToken
} from "../interfaces/agreements/IInstantDistributionAgreementV1.sol";
import {
    ISuperfluid,
    ISuperfluidGovernance,
    ISuperApp
}
from "../interfaces/superfluid/ISuperfluid.sol";
import { AgreementLibrary } from "./AgreementLibrary.sol";

import { UInt128SafeMath } from "../utils/UInt128SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";


contract InstantDistributionAgreementV1 is IInstantDistributionAgreementV1 {

    using SafeMath for uint256;
    using UInt128SafeMath for uint128;
    using SignedSafeMath for int256;

    /// @dev Subscriber state slot id for storing subs bitmap
    uint256 private constant _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID = 0;
    /// @dev Publisher state slot id for storing its deposit amount
    uint256 private constant _PUBLISHER_DEPOSIT_STATE_SLOT_ID = 1 << 32;
    /// @dev Subscriber state slot id starting ptoint for subscription data
    uint256 private constant _SUBSCRIBER_SUB_DATA_STATE_SLOT_ID_START = 1 << 128;

    /// @dev Maximum number of subscriptions a subscriber can have
    uint32 private constant _MAX_NUM_SUBS = 256;
    /// @dev A special id that indicating the subscription is not approved yet
    uint32 private constant _UNALLOCATED_SUB_ID = type(uint32).max;

    /// @dev Agreement data for the index
    struct IndexData {
        uint128 indexValue;
        uint128 totalUnitsApproved;
        uint128 totalUnitsPending;
    }

    /// @dev Agreement data for the subscription
    struct SubscriptionData {
        uint32 subId;
        address publisher;
        uint32 indexId;
        uint128 indexValue;
        uint128 units;
    }

    // Stack data helper to avoid stack too deep errors in some functions
    struct StackData {
        bytes32 iId;
        bytes32 sId;
        IndexData idata;
        SubscriptionData sdata;
        bytes cbdata;
    }

    /// @dev ISuperAgreement.realtimeBalanceOf implementation
    function realtimeBalanceOf(
        ISuperfluidToken token,
        address account,
        uint256 /*time*/
    )
        external view override
        returns (
            int256 dynamicBalance,
            uint256 deposit,
            uint256 /*owedDeposit*/
        )
    {
        bool exist;
        IndexData memory idata;
        SubscriptionData memory sdata;

        // as a subscriber
        // read all subs and calculate the real-time balance
        uint256 subsBitmap = uint256(token.getAgreementStateSlot(
            address(this),
            account,
            _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID, 1)[0]);
        for (uint32 subId = 0; subId < _MAX_NUM_SUBS; ++subId) {
            if ((uint256(subsBitmap >> subId) & 1) == 0) continue;
            bytes32 iId = token.getAgreementStateSlot(
                address(this),
                account,
                _SUBSCRIBER_SUB_DATA_STATE_SLOT_ID_START + subId, 1)[0];
            bytes32 sId = _getSubscriptionId(account, iId);
            (exist, idata) = _getIndexData(token, iId);
            require(exist, "IDAv1: index does not exist");
            (exist, sdata) = _getSubscriptionData(token, sId);
            require(exist, "IDAv1: subscription does not exist");
            require(sdata.subId == subId, "IDAv1: incorrect slot id");
            dynamicBalance = dynamicBalance.add(
                int256(idata.indexValue - sdata.indexValue) * int256(sdata.units)
            );
        }

        // as a publisher
        // calculate the deposits due to pending subscriptions
        deposit = _getPublisherDeposit(token, account);
    }

    /// @dev IInstantDistributionAgreementV1.createIndex implementation
    function createIndex(
        ISuperfluidToken token,
        uint32 indexId,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        address publisher = AgreementLibrary.decodeCtx(ISuperfluid(msg.sender), ctx).msgSender;
        bytes32 iId = _getPublisherId(publisher, indexId);
        require(!_hasIndexData(token, iId), "IDAv1: index already exists");

        token.createAgreement(iId, _encodeIndexData(IndexData(0, 0, 0)));

        emit IndexCreated(token, publisher, indexId);

        // nothing to be recorded so far
        newCtx = ctx;
    }

    /// @dev IInstantDistributionAgreementV1.getIndex implementation
    function getIndex(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId
    )
        external view override
        returns (
            bool exist,
            uint128 indexValue,
            uint128 totalUnitsApproved,
            uint128 totalUnitsPending)
    {
        IndexData memory idata;
        bytes32 iId = _getPublisherId(publisher, indexId);
        (exist, idata) = _getIndexData(token, iId);
        if (exist) {
            indexValue = idata.indexValue;
            totalUnitsApproved = idata.totalUnitsApproved;
            totalUnitsPending = idata.totalUnitsPending;
        }
    }

    /// @dev IInstantDistributionAgreementV1.updateIndex implementation
    function updateIndex(
        ISuperfluidToken token,
        uint32 indexId,
        uint128 indexValue,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        address publisher = AgreementLibrary.decodeCtx(ISuperfluid(msg.sender), ctx).msgSender;
        bytes32 iId = _getPublisherId(publisher, indexId);
        (bool exist, IndexData memory idata) = _getIndexData(token, iId);
        require(exist, "IDAv1: index does not exist");
        require(indexValue >= idata.indexValue, "IDAv1: index value should grow");

        _updateIndex(token, publisher, indexId, iId, idata, indexValue);

        // nothing to be recorded so far
        newCtx = ctx;
    }

    function distribute(
        ISuperfluidToken token,
        uint32 indexId,
        uint256 amount,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        address publisher = AgreementLibrary.decodeCtx(ISuperfluid(msg.sender), ctx).msgSender;
        bytes32 iId = _getPublisherId(publisher, indexId);
        (bool exist, IndexData memory idata) = _getIndexData(token, iId);
        require(exist, "IDAv1: index does not exist");

        uint128 indexDelta = UInt128SafeMath.downcast(
            amount /
            uint256(idata.totalUnitsApproved + idata.totalUnitsPending)
        );
        _updateIndex(token, publisher, indexId, iId, idata, idata.indexValue + indexDelta);

        // nothing to be recorded so far
        newCtx = ctx;
    }

    function _updateIndex(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId,
        bytes32 iId,
        IndexData memory idata,
        uint128 indexValue
    )
        private
    {
        // - settle the publisher balance INSTANT-ly (ding ding ding, IDA)
        //   - adjust static balance directly
        token.settleBalance(publisher,
            (-int256(indexValue - idata.indexValue)).mul(int256(idata.totalUnitsApproved)));
        //   - adjust the publisher's deposit amount
        _adjustPublisherDeposit(token, publisher,
            int256(indexValue - idata.indexValue).mul(int256(idata.totalUnitsPending)));
        // adjust the publisher's index data
        idata.indexValue = indexValue;
        token.updateAgreementData(iId, _encodeIndexData(idata));

        emit IndexUpdated(token, publisher, indexId, indexValue, idata.totalUnitsPending, idata.totalUnitsApproved);

        // check account solvency
        require(!token.isAccountInsolvent(publisher), "IDAv1: insufficient balance");
    }

    function calculateDistribution(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId,
        uint256 amount
    )
        external view override
        returns(
            uint256 actualAmount,
            uint128 newIndexValue)
    {
        bytes32 iId = _getPublisherId(publisher, indexId);
        (bool exist, IndexData memory idata) = _getIndexData(token, iId);
        require(exist, "IDAv1: index does not exist");

        uint256 totalUnits = uint256(idata.totalUnitsApproved + idata.totalUnitsPending);
        uint128 indexDelta = UInt128SafeMath.downcast(amount / totalUnits);
        newIndexValue = idata.indexValue.add(indexDelta);
        actualAmount = uint256(indexDelta).mul(totalUnits);
    }

    /// @dev IInstantDistributionAgreementV1.approveSubscription implementation
    function approveSubscription(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        bool exist;
        StackData memory sd;
        address subscriber = AgreementLibrary.decodeCtx(ISuperfluid(msg.sender), ctx).msgSender;
        sd.iId = _getPublisherId(publisher, indexId);
        sd.sId = _getSubscriptionId(subscriber, sd.iId);
        (exist, sd.idata) = _getIndexData(token, sd.iId);
        require(exist, "IDAv1: index does not exist");
        (exist, sd.sdata) = _getSubscriptionData(token, sd.sId);
        if (exist) {
            // sanity check
            require(sd.sdata.publisher == publisher, "IDAv1: incorrect publisher");
            require(sd.sdata.indexId == indexId, "IDAv1: incorrect indexId");
            // required condition check
            require(sd.sdata.subId == _UNALLOCATED_SUB_ID, "IDAv1: subscription already approved");
        }

        if (!exist) {
            (sd.cbdata, newCtx) = AgreementLibrary.beforeAgreementCreated(
                ISuperfluid(msg.sender), token, ctx,
                address(this), publisher, sd.sId
            );

            sd.sdata = SubscriptionData({
                publisher: publisher,
                indexId: indexId,
                subId: 0,
                units: 0,
                indexValue: sd.idata.indexValue
            });
            // add to subscription list of the subscriber
            sd.sdata.subId = _findAndFillSubsBitmap(token, subscriber, sd.iId);
            token.createAgreement(sd.sId, _encodeSubscriptionData(sd.sdata));

            newCtx = AgreementLibrary.afterAgreementCreated(
                ISuperfluid(msg.sender), token, newCtx,
                address(this), publisher, sd.sId, sd.cbdata
            );
        } else {
            (sd.cbdata, newCtx) = AgreementLibrary.beforeAgreementUpdated(
                ISuperfluid(msg.sender), token, ctx,
                address(this), publisher, sd.sId
            );

            int balanceDelta = int256(sd.idata.indexValue - sd.sdata.indexValue) * int256(sd.sdata.units);

            // update publisher data and adjust publisher's deposits
            sd.idata.totalUnitsApproved += sd.sdata.units;
            sd.idata.totalUnitsPending -= sd.sdata.units;
            token.updateAgreementData(sd.iId, _encodeIndexData(sd.idata));
            _adjustPublisherDeposit(token, publisher, -balanceDelta);
            token.settleBalance(publisher, -balanceDelta);

            // update subscription data and adjust subscriber's balance
            token.settleBalance(subscriber, balanceDelta);
            sd.sdata.indexValue = sd.idata.indexValue;
            sd.sdata.subId = _findAndFillSubsBitmap(token, subscriber, sd.iId);
            token.updateAgreementData(sd.sId, _encodeSubscriptionData(sd.sdata));

            newCtx = AgreementLibrary.afterAgreementUpdated(
                ISuperfluid(msg.sender), token, newCtx,
                address(this), publisher, sd.sId, sd.cbdata
            );
        }

        // can index up to three words, hence splitting into two events from publisher or subscriber's view.
        emit IndexSubscribed(token, publisher, indexId, subscriber);
        emit SubscriptionApproved(token, subscriber, publisher, indexId);
    }

    /// @dev IInstantDistributionAgreementV1.updateSubscription implementation
    function updateSubscription(
        ISuperfluidToken token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        bool exist;
        StackData memory sd;
        address publisher = AgreementLibrary.decodeCtx(ISuperfluid(msg.sender), ctx).msgSender;
        bytes32 iId = _getPublisherId(publisher, indexId);
        bytes32 sId = _getSubscriptionId(subscriber, iId);
        (exist, sd.idata) = _getIndexData(token, iId);
        require(exist, "IDAv1: index does not exist");
        (exist, sd.sdata) = _getSubscriptionData(token, sId);
        if (exist) {
            // sanity check
            require(sd.sdata.publisher == publisher, "IDAv1: incorrect publisher");
            require(sd.sdata.indexId == indexId, "IDAv1: incorrect indexId");
        }

        // before-hook callback
        if (exist) {
            (sd.cbdata, newCtx) = AgreementLibrary.beforeAgreementUpdated(
                ISuperfluid(msg.sender), token, ctx,
                address(this), subscriber, sId
            );
        } else {
            (sd.cbdata, newCtx) = AgreementLibrary.beforeAgreementCreated(
                ISuperfluid(msg.sender), token, ctx,
                address(this), subscriber, sId
            );
        }

        // update publisher data
        if (exist && sd.sdata.subId != _UNALLOCATED_SUB_ID) {
            // if the subscription exist and not approved, update the approved units amount

            // update total units
            sd.idata.totalUnitsApproved = UInt128SafeMath.downcast(
                uint256(sd.idata.totalUnitsApproved) +
                uint256(units) -
                uint256(sd.sdata.units)
            );
            token.updateAgreementData(iId, _encodeIndexData(sd.idata));
        } else if (exist) {
            // if the subscription exists and approved, update the pending units amount

            // update pending subscription units of the publisher
            sd.idata.totalUnitsPending = UInt128SafeMath.downcast(
                uint256(sd.idata.totalUnitsPending) +
                uint256(units) -
                uint256(sd.sdata.units)
            );
            token.updateAgreementData(iId, _encodeIndexData(sd.idata));
        } else {
            // if the subscription does not exist, create it and then update the pending units amount

            // create unallocated subscription
            sd.sdata = SubscriptionData({
                publisher: publisher,
                indexId: indexId,
                subId: _UNALLOCATED_SUB_ID,
                units: units,
                indexValue: sd.idata.indexValue
            });
            token.createAgreement(sId, _encodeSubscriptionData(sd.sdata));

            sd.idata.totalUnitsPending = sd.idata.totalUnitsPending.add(units);
            token.updateAgreementData(iId, _encodeIndexData(sd.idata));
        }

        int256 balanceDelta = int256(sd.idata.indexValue - sd.sdata.indexValue) * int256(sd.sdata.units);

        // adjust publisher's deposit and balances if subscription is pending
        if (sd.sdata.subId == _UNALLOCATED_SUB_ID) {
            _adjustPublisherDeposit(token, publisher, -balanceDelta);
            token.settleBalance(publisher, -balanceDelta);
        }

        // settle subscriber static balance
        token.settleBalance(subscriber, balanceDelta);

        // update subscription data if necessary
        if (exist) {
            sd.sdata.indexValue = sd.idata.indexValue;
            sd.sdata.units = units;
            token.updateAgreementData(sId, _encodeSubscriptionData(sd.sdata));
        }

        // check account solvency
        require(!token.isAccountInsolvent(publisher), "IDAv1: insufficient balance");

        // after-hook callback
        if (exist) {
            newCtx = AgreementLibrary.afterAgreementUpdated(
                ISuperfluid(msg.sender), token, newCtx,
                address(this), subscriber, sId, sd.cbdata
            );
        } else {
            newCtx = AgreementLibrary.afterAgreementCreated(
                ISuperfluid(msg.sender), token, newCtx,
                address(this), subscriber, sId, sd.cbdata
            );
        }

        emit IndexUnitsUpdated(token, publisher, indexId, subscriber, units);
        emit SubscriptionUnitsUpdated(token, subscriber, publisher, indexId, units);
    }

    /// @dev IInstantDistributionAgreementV1.getSubscription implementation
    function getSubscription(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    )
        external view override
        returns (
            bool approved,
            uint128 units,
            uint256 pendingDistribution
        )
    {
        bool exist;
        IndexData memory idata;
        SubscriptionData memory sdata;
        bytes32 iId = _getPublisherId(publisher, indexId);
        (exist, idata) = _getIndexData(token, iId);
        require(exist, "IDAv1: index does not exist");
        bytes32 sId = _getSubscriptionId(subscriber, iId);
        (exist, sdata) = _getSubscriptionData(token, sId);
        require(exist, "IDAv1: subscription does not exist");
        require(sdata.publisher == publisher, "IDAv1: incorrect publisher");
        require(sdata.indexId == indexId, "IDAv1: incorrect indexId");
        approved = sdata.subId != _UNALLOCATED_SUB_ID;
        units = sdata.units;
        pendingDistribution = approved ? 0 :
            uint256(idata.indexValue - sdata.indexValue) * uint256(sdata.units);
    }

    /// @dev IInstantDistributionAgreementV1.getSubscriptionByID implementation
    function getSubscriptionByID(
       ISuperfluidToken token,
       bytes32 agreementId
    )
       external view override
       returns(
           address publisher,
           uint32 indexId,
           bool approved,
           uint128 units,
           uint256 pendingDistribution
       )
    {
        bool exist;
        IndexData memory idata;
        SubscriptionData memory sdata;
        (exist, sdata) = _getSubscriptionData(token, agreementId);
        require(exist, "IDAv1: subscription does not exist");

        publisher = sdata.publisher;
        indexId = sdata.indexId;
        bytes32 iId = _getPublisherId(publisher, indexId);
        (exist, idata) = _getIndexData(token, iId);
        require(exist, "IDAv1: index does not exist");

        approved = sdata.subId != _UNALLOCATED_SUB_ID;
        units = sdata.units;
        pendingDistribution = approved ? 0 :
            uint256(idata.indexValue - sdata.indexValue) * uint256(sdata.units);
    }

    /// @dev IInstantDistributionAgreementV1.listSubscriptions implementation
    function listSubscriptions(
        ISuperfluidToken token,
        address subscriber
    )
        external view override
        returns(
            address[] memory publishers,
            uint32[] memory indexIds,
            uint128[] memory unitsList)
    {
        uint256 subsBitmap = uint256(token.getAgreementStateSlot(
            address(this),
            subscriber,
            _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID, 1)[0]);
        bool exist;
        SubscriptionData memory sdata;
        // read all slots
        uint nSlots;
        publishers = new address[](_MAX_NUM_SUBS);
        indexIds = new uint32[](_MAX_NUM_SUBS);
        unitsList = new uint128[](_MAX_NUM_SUBS);
        for (uint32 subId = 0; subId < _MAX_NUM_SUBS; ++subId) {
            if ((uint256(subsBitmap >> subId) & 1) == 0) continue;
            bytes32 iId = token.getAgreementStateSlot(
                address(this),
                subscriber,
                _SUBSCRIBER_SUB_DATA_STATE_SLOT_ID_START + subId, 1)[0];
            bytes32 sId = _getSubscriptionId(subscriber, iId);
            (exist, sdata) = _getSubscriptionData(token, sId);
            require(exist, "IDAv1: subscription does not exist");
            require(sdata.subId == subId, "IDAv1: incorrect slot id");
            publishers[nSlots] = sdata.publisher;
            indexIds[nSlots] = sdata.indexId;
            unitsList[nSlots] = sdata.units;
            ++nSlots;
        }
        // resize memory arrays
        assembly {
            mstore(publishers, nSlots)
            mstore(indexIds, nSlots)
            mstore(unitsList, nSlots)
        }
    }

    /// @dev IInstantDistributionAgreementV1.deleteSubscription implementation
    function deleteSubscription(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        bool exist;
        StackData memory sd;
        address sender = AgreementLibrary.decodeCtx(ISuperfluid(msg.sender), ctx).msgSender;
        require(sender == publisher || sender == subscriber, "IDAv1: operation not allowed");
        sd.iId = _getPublisherId(publisher, indexId);
        sd.sId = _getSubscriptionId(subscriber, sd.iId);
        (exist, sd.idata) = _getIndexData(token, sd.iId);
        require(exist, "IDAv1: index does not exist");
        (exist, sd.sdata) = _getSubscriptionData(token, sd.sId);
        require(exist, "IDAv1: subscription does not exist");
        require(sd.sdata.publisher == publisher, "IDAv1: incorrect publisher");
        require(sd.sdata.indexId == indexId, "IDAv1: incorrect indexId");

        (sd.cbdata, newCtx) = AgreementLibrary.beforeAgreementTerminated(
            ISuperfluid(msg.sender), token, ctx,
            address(this), sender == subscriber ? publisher : subscriber, sd.sId
        );

        int256 balanceDelta = int256(sd.idata.indexValue - sd.sdata.indexValue) * int256(sd.sdata.units);

        // update publisher index agreement data
        if (sd.sdata.subId != _UNALLOCATED_SUB_ID) {
            sd.idata.totalUnitsApproved = sd.idata.totalUnitsApproved.sub(sd.sdata.units);
        } else {
            sd.idata.totalUnitsPending = sd.idata.totalUnitsPending.sub(sd.sdata.units);
        }
        token.updateAgreementData(sd.iId, _encodeIndexData(sd.idata));

        // terminate subscription agreement data
        token.terminateAgreement(sd.sId, 2);
        // remove subscription from subscriber's bitmap
        if (sd.sdata.subId != _UNALLOCATED_SUB_ID) {
            _clearSubsBitmap(token, subscriber, sd.sdata);
        }

        // move from publisher's deposit to static balance
        if (sd.sdata.subId == _UNALLOCATED_SUB_ID) {
            _adjustPublisherDeposit(token, publisher, -balanceDelta);
            token.settleBalance(publisher, -balanceDelta);
        }

        // settle subscriber static balance
        token.settleBalance(subscriber, balanceDelta);

        newCtx = AgreementLibrary.afterAgreementTerminated(
            ISuperfluid(msg.sender), token, newCtx,
            address(this), sender == subscriber ? publisher : subscriber, sd.sId, sd.cbdata
        );

        emit IndexUnsubscribed(token, publisher, indexId, subscriber);
        emit SubscriptionDeleted(token, subscriber, publisher, indexId);
    }

    function claim(
        ISuperfluidToken token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    )
        external override
        returns(bytes memory newCtx)
    {
        bool exist;
        StackData memory sd;
        sd.iId = _getPublisherId(publisher, indexId);
        sd.sId = _getSubscriptionId(subscriber, sd.iId);
        (exist, sd.idata) = _getIndexData(token, sd.iId);
        require(exist, "IDAv1: index does not exist");
        (exist, sd.sdata) = _getSubscriptionData(token, sd.sId);
        require(exist, "IDAv1: subscription does not exist");
         // sanity check
        require(sd.sdata.publisher == publisher, "IDAv1: incorrect publisher");
        require(sd.sdata.indexId == indexId, "IDAv1: incorrect indexId");
        // required condition check
        require(sd.sdata.subId == _UNALLOCATED_SUB_ID, "IDAv1: subscription already approved");

        uint256 pendingDistribution = uint256(sd.idata.indexValue - sd.sdata.indexValue) * uint256(sd.sdata.units);

        if (pendingDistribution > 0) {
            (sd.cbdata, newCtx) = AgreementLibrary.beforeAgreementUpdated(
                ISuperfluid(msg.sender), token, ctx,
                address(this), publisher, sd.sId
            );

            // adjust publisher's deposits
            _adjustPublisherDeposit(token, publisher, -int256(pendingDistribution));
            token.settleBalance(publisher, -int256(pendingDistribution));

            // update subscription data and adjust subscriber's balance
            sd.sdata.indexValue = sd.idata.indexValue;
            token.updateAgreementData(sd.sId, _encodeSubscriptionData(sd.sdata));
            token.settleBalance(subscriber, int256(pendingDistribution));

            newCtx = AgreementLibrary.afterAgreementUpdated(
                ISuperfluid(msg.sender), token, newCtx,
                address(this), publisher, sd.sId, sd.cbdata
            );
        } else {
            // nothing to be recorded in this case
            newCtx = ctx;
        }
    }

    function _getPublisherId(
        address publisher,
        uint32 indexId)
        private pure
        returns (bytes32 iId)
    {
        return keccak256(abi.encodePacked("publisher", publisher, indexId));
    }

    function _getSubscriptionId(
        address subscriber,
        bytes32 iId)
        private pure
        returns (bytes32 sId)
    {
        return keccak256(abi.encodePacked("subscription", subscriber, iId));
    }

    // # Index data operations
    //
    // Data packing:
    //
    // WORD 1: | existence bit  | indexValue |
    //         | 128b           | 128b       |
    // WORD 2: | totalUnitsPending | totalUnitsApproved |
    //         | 128b              | 12b                |

    function _encodeIndexData(
        IndexData memory idata)
        private pure
        returns (bytes32[] memory data) {
        data = new bytes32[](2);
        data[0] = bytes32(
            uint256(1 << 128) /* existance bit */ |
            uint256(idata.indexValue)
        );
        data[1] = bytes32(
            (uint256(idata.totalUnitsApproved)) |
            (uint256(idata.totalUnitsPending) << 128)
        );
    }

    function _hasIndexData(
        ISuperfluidToken token,
        bytes32 iId)
        private view
        returns (bool exist)
    {
        bytes32[] memory adata = token.getAgreementData(address(this), iId, 2);
        uint256 a = uint256(adata[0]);
        exist = a > 0;
    }

    function _getIndexData(
        ISuperfluidToken token,
        bytes32 iId)
        private view
        returns (bool exist, IndexData memory idata)
    {
        bytes32[] memory adata = token.getAgreementData(address(this), iId, 2);
        uint256 a = uint256(adata[0]);
        uint256 b = uint256(adata[1]);
        exist = a > 0;
        if (exist) {
            idata.indexValue = uint128(a & uint256(int128(-1)));
            idata.totalUnitsApproved = uint128(b & uint256(int128(-1)));
            idata.totalUnitsPending = uint128(b >> 128);
        }
    }


    // # Publisher's deposit amount
    //
    // It is stored in state slot in one word

    function _getPublisherDeposit(
        ISuperfluidToken token,
        address publisher
    )
        private view
        returns (uint256)
    {
        bytes32[] memory data = token.getAgreementStateSlot(
            address(this),
            publisher,
            _PUBLISHER_DEPOSIT_STATE_SLOT_ID,
            1);
        return uint256(data[0]);
    }

    function _adjustPublisherDeposit(
        ISuperfluidToken token,
        address publisher,
        int256 delta
    )
        private
    {
        if (delta == 0) return;
        bytes32[] memory data = token.getAgreementStateSlot(
            address(this),
            publisher,
            _PUBLISHER_DEPOSIT_STATE_SLOT_ID,
            1);
        data[0] = bytes32(int256(data[0]) + delta);
        token.updateAgreementStateSlot(
            publisher,
            _PUBLISHER_DEPOSIT_STATE_SLOT_ID,
            data);
    }

    // # Subscription data operations
    //
    // Data packing:
    //
    // WORD 1: | publisher | RESERVED | indexId | subId |
    //         | 160b      | 32b      | 32b     | 32b   |
    // WORD 2: | units | indexValue |
    //         | 128b  | 128b       |

    function _encodeSubscriptionData(
        SubscriptionData memory sdata)
        private pure
        returns (bytes32[] memory data)
    {
        data = new bytes32[](2);
        data[0] = bytes32(
            (uint256(sdata.publisher) << (12*8)) |
            (uint256(sdata.indexId) << 32) |
            uint256(sdata.subId)
        );
        data[1] = bytes32(
            uint256(sdata.indexValue) |
            (uint256(sdata.units) << 128)
        );
    }

    function _getSubscriptionData(
        ISuperfluidToken token,
        bytes32 sId)
        private view
        returns (bool exist, SubscriptionData memory sdata)
    {
        bytes32[] memory adata = token.getAgreementData(address(this), sId, 2);
        uint256 a = uint256(adata[0]);
        uint256 b = uint256(adata[1]);
        exist = a > 0;
        if (exist) {
            sdata.publisher = address(uint160(a >> (12*8)));
            sdata.indexId = uint32((a >> 32) & type(uint32).max);
            sdata.subId = uint32(a & type(uint32).max);
            sdata.indexValue = uint128(b & uint256(int128(-1)));
            sdata.units = uint128(b >> 128);
        }
    }

    // # Subscription bitmap operations
    //
    // ## Subscription bitmap state slot
    //
    // slotId: _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID)
    //
    // Subscriber can store up to _MAX_NUM_SUBS amount of subscriptions.
    // For each subscription approved it allocated with a subId with a value in [0, _MAX_NUM_SUBS).
    // The allocation is to fill one bit in the subscription bitmap.
    //
    // ## Subscription reference state slots
    //
    // slotId: _SUBSCRIBER_SUB_DATA_STATE_SLOT_ID_START + subId)
    //
    // It stores the index data ID.

    function _findAndFillSubsBitmap(
        ISuperfluidToken token,
        address subscriber,
        bytes32 iId
    )
        private
        returns (uint32 subId)
    {
        uint256 subsBitmap = uint256(token.getAgreementStateSlot(
            address(this),
            subscriber,
            _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID, 1)[0]);
        for (subId = 0; subId < _MAX_NUM_SUBS; ++subId) {
            if ((uint256(subsBitmap >> subId) & 1) == 0) {
                // update slot data
                bytes32[] memory slotData = new bytes32[](1);
                slotData[0] = iId;
                token.updateAgreementStateSlot(
                    subscriber,
                    _SUBSCRIBER_SUB_DATA_STATE_SLOT_ID_START + subId,
                    slotData);
                // update slot map
                slotData[0] = bytes32(subsBitmap | (1 << uint256(subId)));
                token.updateAgreementStateSlot(
                    subscriber,
                    _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID,
                    slotData);
                // update the slots
                break;
            }
        }
    }

    function _clearSubsBitmap(
        ISuperfluidToken token,
        address subscriber,
        SubscriptionData memory sdata
    )
        private
    {
        uint256 subsBitmap = uint256(token.getAgreementStateSlot(
            address(this),
            subscriber,
            _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID, 1)[0]);
        bytes32[] memory slotData = new bytes32[](1);
        slotData[0] = bytes32(subsBitmap & ~(1 << uint256(sdata.subId)));
        // zero the data
        token.updateAgreementStateSlot(
            subscriber,
            _SUBSCRIBER_SUBS_BITMAP_STATE_SLOT_ID,
            slotData);
    }
}