// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IAlgebraFarmingProxyPluginFactory {
    function createAlgebraProxyPlugin(
        address _pool,
        address _factory,
        address _pluginFactory
    ) external returns (address);
}
