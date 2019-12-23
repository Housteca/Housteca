pragma solidity 0.6.0;


import "ERC1400/contracts/ERC1400.sol";


contract Property is ERC1400
{
    constructor()
      public
      ERC1400("Housteca", "HTC", 18, new address[](0), msg.sender, new bytes32[](0))
    {

    }
}
