pragma solidity 0.5.13;


import "openzeppelin-solidity/contracts/token/ERC777/ERC777.sol";


contract TestERC777Token is ERC777 {
    constructor()
      public
      ERC777("TestERC777Token", "T777", new address[](0))
    {
        _mint(msg.sender, msg.sender, 100000000000 * (10 ** 18), "", "");
    }
}