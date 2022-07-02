// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import {Test} from 'forge-std/Test.sol';
import {BoundLayerableTestImpl} from 'bound-layerable/test/BoundLayerableTestImpl.sol';
import {PackedByteUtility} from 'bound-layerable/lib/PackedByteUtility.sol';
import {LayerVariation} from 'bound-layerable/interface/Structs.sol';
import {BoundLayerableEvents} from 'bound-layerable/interface/Events.sol';
import {ArrayLengthMismatch, LayerNotBoundToTokenId, MultipleVariationsEnabled, DuplicateActiveLayers} from 'bound-layerable/interface/Errors.sol';

library Helpers {
    function generateVariationMask(
        uint256 _layers,
        LayerVariation memory variation
    ) internal pure returns (uint256) {
        for (
            uint256 i = variation.layerId;
            i < variation.layerId + variation.numVariations;
            i++
        ) {
            _layers |= 1 << i;
        }
        return _layers;
    }
}

contract BoundLayerableTest is Test, BoundLayerableEvents {
    BoundLayerableTestImpl test;

    function setUp() public {
        test = new BoundLayerableTestImpl();
        test.mint();
        test.setTraitGenerationSeed(bytes32(bytes1(0x01)));
        uint256[] memory layers = new uint256[](2);
        layers[0] = 1;
        layers[1] = 2;
    }

    function testLayerIsBoundToTokenId() public {
        assertFalse(test.layerIsBoundToTokenId(0, 0));
        // technically true - should never happen
        // TODO: SAFEGUARD
        assertTrue(test.layerIsBoundToTokenId(0x1, 0));

        assertTrue(test.layerIsBoundToTokenId(0x2, 1));
        assertTrue(test.layerIsBoundToTokenId(0x4, 2));
        assertTrue(test.layerIsBoundToTokenId(0xFF << 248, 255));
        assertTrue(test.layerIsBoundToTokenId((0xFF << 248) | 2, 1));
    }

    function testSetBoundLayers() public {
        test.setBoundLayers(0, (0xFF << 248) | 2);
        assertEq(test.getBoundLayerBitMap(0), (0xFF << 248) | 2);
        test.setBoundLayers(0, 14);
        assertEq(test.getBoundLayerBitMap(0), 14);
        test.setBoundLayers(0, 1);
        // test we do not set 0th bit
        assertEq(test.getBoundLayerBitMap(1), 0);
    }

    // function testSetBoundLayersBulk() public {
    //     uint256[] memory tokenIds = new uint256[](4);
    //     tokenIds[0] = 1;
    //     tokenIds[1] = 2;
    //     tokenIds[2] = 3;
    //     tokenIds[3] = 4;
    //     uint256[] memory layerBindingBitMap = new uint256[](4);
    //     layerBindingBitMap[0] = 1 << 255;
    //     layerBindingBitMap[1] = 3 << 254;
    //     // 0th bit shouldn't be set
    //     layerBindingBitMap[2] = (3 << 254) | 1;
    //     layerBindingBitMap[3] = (3 << 254) | 2;

    //     test.setBoundLayersBulk(tokenIds, layerBindingBitMap);
    //     assertEq(test.getBoundLayerBitMap(1), 1 << 255);
    //     assertEq(test.getBoundLayerBitMap(2), 3 << 254);
    //     //0th bit shouldn't be set
    //     assertEq(test.getBoundLayerBitMap(3), 3 << 254);
    //     assertEq(test.getBoundLayerBitMap(4), (3 << 254) | 2);
    // }

    // function testSetBoundLayersBulk_unequalLengths() public {
    //     uint256[] memory tokenIds = new uint256[](4);
    //     tokenIds[0] = 1;
    //     tokenIds[1] = 2;
    //     tokenIds[2] = 3;
    //     tokenIds[3] = 4;
    //     uint256[] memory layerBindingBitMap = new uint256[](3);
    //     layerBindingBitMap[0] = 1 << 255;
    //     layerBindingBitMap[1] = 3 << 254;
    //     layerBindingBitMap[2] = (3 << 254) | 2;

    //     vm.expectRevert(
    //         abi.encodePacked(
    //             ArrayLengthMismatch.selector,
    //             uint256(4),
    //             uint256(3)
    //         )
    //     );
    //     test.setBoundLayersBulk(tokenIds, layerBindingBitMap);
    // }

    function testCheckUnpackedIsSubsetOfBound() public {
        // pass: bound is superset of unpacked
        uint256 boundLayers = (0xFF << 248) | 2;
        uint256 unpackedLayers = 0xFF << 248;
        test.checkUnpackedIsSubsetOfBound(unpackedLayers, boundLayers);

        // pass: bound is identical to unpacked
        boundLayers = 0xFF << 248;
        unpackedLayers = 0xFF << 248;
        test.checkUnpackedIsSubsetOfBound(unpackedLayers, boundLayers);

        // revert: bound is subset of unpacked
        boundLayers = unpackedLayers;
        unpackedLayers |= 2;
        vm.expectRevert(LayerNotBoundToTokenId.selector);
        test.checkUnpackedIsSubsetOfBound(unpackedLayers, boundLayers);

        // revert: unpacked and bound are disjoint
        boundLayers = 2;
        unpackedLayers = 0xFF << 248;
        vm.expectRevert(LayerNotBoundToTokenId.selector);
        test.checkUnpackedIsSubsetOfBound(unpackedLayers, boundLayers);
    }

    function testCheckForMultipleVariations() public {
        uint256 boundLayers = 0;
        LayerVariation[] memory variations = test.getVariations();
        // pass: no variations
        boundLayers = Helpers.generateVariationMask(boundLayers, variations[0]);
        boundLayers = Helpers.generateVariationMask(0, variations[1]);
        boundLayers |= 255;
        boundLayers |= 42;

        uint256 unpackedLayers = 0;
        test.checkForMultipleVariations(boundLayers, unpackedLayers);

        // pass: one of each variation
        unpackedLayers = (1 << 200) | (1 << 4);
        test.checkForMultipleVariations(boundLayers, unpackedLayers);

        // pass: different variations
        unpackedLayers = (1 << 201) | (1 << 5);
        test.checkForMultipleVariations(boundLayers, unpackedLayers);

        // pass: variations plus other layers
        unpackedLayers = (1 << 208) | (1 << 12) | (1 << 42) | (1 << 255);
        test.checkForMultipleVariations(boundLayers, unpackedLayers);

        // revert: multiple variations
        unpackedLayers = (1 << 200) | (1 << 201) | (1 << 42) | (1 << 255);
        vm.expectRevert(MultipleVariationsEnabled.selector);
        test.checkForMultipleVariations(boundLayers, unpackedLayers);

        // revert: multiple multiple variations (same variation)
        unpackedLayers =
            (1 << 200) |
            (1 << 201) |
            (1 << 202) |
            (1 << 42) |
            (1 << 255);
        vm.expectRevert(MultipleVariationsEnabled.selector);
        test.checkForMultipleVariations(boundLayers, unpackedLayers);

        // revert: multiple multiple variations (different variations)
        unpackedLayers =
            (1 << 200) |
            (1 << 201) |
            (1 << 202) |
            (1 << 4) |
            (1 << 5) |
            (1 << 12) |
            (1 << 42) |
            (1 << 255);
        vm.expectRevert(MultipleVariationsEnabled.selector);
        test.checkForMultipleVariations(boundLayers, unpackedLayers);
    }

    function testUnpackLayersToBitMapAndCheckForDuplicates() public {
        uint256[] memory layers = new uint256[](4);
        layers[0] = 1;
        layers[1] = 2;
        layers[2] = 3;
        layers[3] = 4;
        uint256[] memory packedLayers = PackedByteUtility.packBytearray(layers);

        // // pass: < 32 length no duplicates
        test.unpackLayersToBitMapAndCheckForDuplicates(packedLayers);

        layers = new uint256[](33);
        for (uint256 i; i < layers.length; ++i) {
            layers[i] = uint256(i + 1);
        }
        // // pass: > 32 length no duplicates
        test.unpackLayersToBitMapAndCheckForDuplicates(
            PackedByteUtility.packBytearray(layers)
        );

        // fail: 32 length; last duplicate
        layers = new uint256[](32);
        for (uint256 i; i < layers.length; ++i) {
            layers[i] = uint256(i + 1);
        }
        layers[31] = layers[30];
        packedLayers = PackedByteUtility.packBytearray(layers);

        vm.expectRevert(DuplicateActiveLayers.selector);
        test.unpackLayersToBitMapAndCheckForDuplicates(packedLayers);

        // // fail: 33 length; duplicate on uint in array
        layers = new uint256[](33);
        for (uint256 i; i < layers.length; ++i) {
            layers[i] = uint256(i + 5);
        }
        layers[32] = layers[31];
        packedLayers = PackedByteUtility.packBytearray(layers);
        vm.expectRevert(DuplicateActiveLayers.selector);
        test.unpackLayersToBitMapAndCheckForDuplicates(packedLayers);
    }

    function testSetActiveLayers() public {
        uint256 boundLayers = 0;
        LayerVariation[] memory variations = test.getVariations();
        boundLayers = Helpers.generateVariationMask(boundLayers, variations[0]);
        boundLayers = Helpers.generateVariationMask(boundLayers, variations[1]);
        boundLayers |= 1 << 255;
        boundLayers |= 1 << 42;
        test.setBoundLayers(0, boundLayers);
        uint256[] memory layers = new uint256[](4);
        layers[0] = 42;
        layers[1] = 255;
        layers[2] = 4;
        layers[3] = 200;
        uint256[] memory activeLayers = PackedByteUtility.packBytearray(layers);
        test.setActiveLayers(0, activeLayers);

        assertEq(test.getActiveLayersRaw(0)[0], activeLayers[0]);
    }

    // todo: skip, need way to allocate memory
    function testGetActiveLayers() public {
        test.removeVariations();
        uint256 boundlayers = 2**256 - 1;
        test.setBoundLayers(0, boundlayers);
        uint256[] memory layers = new uint256[](255);
        for (uint256 i = 0; i < layers.length; ++i) {
            layers[i] = uint256(i + 1);
        }
        uint256[] memory packedLayers = PackedByteUtility.packBytearray(layers);
        test.setActiveLayers(0, packedLayers);
        uint256[] memory activeLayers = test.getActiveLayers(0);
        emit log_named_uint('activeLayers.length', activeLayers.length);
        // emit log_named_uint("activeLayers[255]", activeLayers[255]);
        assertEq(activeLayers.length, 255);
        for (uint256 i; i < activeLayers.length; ++i) {
            assertEq(activeLayers[i], i + 1);
        }
    }

    function testGetActiveLayersNoLayers() public view {
        test.getActiveLayers(0);
    }

    function testburnAndBindSingle() public {
        vm.expectEmit(true, true, false, false, address(test));
        emit LayersBoundToToken(6, ((1 << 2) | (1 << 7)));
        test.burnAndBindSingle(6, 1);
        assertTrue(test.isBurned(1));
        assertFalse(test.isBurned(6));
        uint256 bindings = test.getBoundLayerBitMap(6);

        uint256[] memory boundLayers = test.getBoundLayers(6);
        assertEq(boundLayers.length, 2);
        assertEq(boundLayers[0], 2);
        assertEq(boundLayers[1], 7);

        // test bind unowned layer to owned
    }

    function test_snapshotburnAndBindMultiple() public {
        uint256[] memory layers = new uint256[](6);
        layers[0] = 0;
        layers[1] = 1;
        layers[2] = 2;
        layers[3] = 3;
        layers[4] = 4;
        layers[5] = 5;
        test.burnAndBindMultiple(6, layers);
    }

    function testburnAndBindMultiple() public {
        uint256[] memory layers = new uint256[](2);
        layers[0] = 1;
        layers[1] = 2;
        vm.expectEmit(true, true, false, false, address(test));
        emit LayersBoundToToken(6, ((1 << 2) | (1 << 3) | (1 << 7)));
        test.burnAndBindMultiple(6, layers);
        assertTrue(test.isBurned(1));
        assertTrue(test.isBurned(2));
        assertFalse(test.isBurned(6));
        uint256 bindings = test.getBoundLayerBitMap(6);
        emit log_named_uint('bindings', bindings);
        uint256[] memory boundLayers = test.getBoundLayers(6);
        assertEq(boundLayers.length, 3);
        assertEq(boundLayers[0], 2);
        assertEq(boundLayers[1], 3);
        assertEq(boundLayers[2], 7);
    }

    // todo: test this in real-world circumstances where layer-id is compared against trait seed
    function test_snapshotburnAndBindSingle() public {
        test.burnAndBindSingle(6, 1);
    }
}