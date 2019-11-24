pragma solidity 0.5.13;


import "openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";


contract TestERC20Token is ERC20, ERC20Detailed {
    constructor()
      public
      ERC20Detailed("TestERC20Token", "T20", 18)
    {
        _mint(msg.sender, 100000000000 * (10 ** 18));
    }
}