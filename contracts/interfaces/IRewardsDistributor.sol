// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IRewardsDistributor {
    function checkpoint_token() external;
    function voting_escrow() external view returns(address);
    function claimable(uint _tokenId) external view returns (uint);
    function claim(uint _tokenId) external returns (uint);
}
