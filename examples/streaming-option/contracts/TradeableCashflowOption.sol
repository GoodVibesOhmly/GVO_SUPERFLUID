 //SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;


import {RedirectAllOption, ISuperToken, IConstantFlowAgreementV1, ISuperfluid} from "./RedirectAllOption.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";


contract TradeableCashflowOption is ERC721, RedirectAllOption {

  constructor (
    address owner,
    string memory _name,
    string memory _symbol,
    ISuperfluid host,
    IConstantFlowAgreementV1 cfa,
    ISuperToken acceptedToken
  )
    ERC721 ( _name, _symbol )
    RedirectAllOption (
      host,
      cfa,
      acceptedToken,
      owner
     )
      {

      _mint(owner, 1);
  }

  //now I will insert a nice little hook in the _transfer, including the RedirectAll function I need
  function _beforeTokenTransfer(
    address /*from*/,
    address to,
    uint256 /*tokenId*/
  ) internal override {
      _changeReceiver(to);
  }
}