import { Address } from "@graphprotocol/graph-ts";
import {
    AgreementLiquidatedBy as AgreementLiquidatedByEvent,
    TokenDowngraded as TokenDowngradedEvent,
    TokenUpgraded as TokenUpgradedEvent,
    Transfer as TransferEvent,
} from "../../../generated/templates/SuperToken/ISuperToken";
import { GOERLI_HOST_ADDRESS } from "../../utils";
import {
    handleAgreementLiquidatedBy,
    handleTokenDowngraded,
    handleTokenUpgraded,
    handleTransfer,
} from "./superTokenBase";

let HOST_ADDRESS = Address.fromString(GOERLI_HOST_ADDRESS);

export function goerliHandleAgreementLiquidatedBy(
    event: AgreementLiquidatedByEvent
): void {
    handleAgreementLiquidatedBy(event, HOST_ADDRESS);
}

export function goerliHandleTokenUpgraded(event: TokenUpgradedEvent): void {
    handleTokenUpgraded(event, HOST_ADDRESS);
}

export function goerliHandleTokenDowngraded(event: TokenDowngradedEvent): void {
    handleTokenDowngraded(event, HOST_ADDRESS);
}

export function goerliHandleTransfer(event: TransferEvent): void {
    handleTransfer(event, HOST_ADDRESS);
}