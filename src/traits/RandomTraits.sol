// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {BAD_DISTRIBUTIONS_SIGNATURE} from '../interface/Constants.sol';
import {BadDistributions, InvalidLayerType} from '../interface/Errors.sol';
import {BatchVRFConsumer} from '../vrf/BatchVRFConsumer.sol';

abstract contract RandomTraits is BatchVRFConsumer {
    // 32 possible traits per layerType given uint8 distributions
    // except final trait type, which has 31, because 0 is not a valid layerId.
    // Function getLayerId will check if layerSeed is less than the distribution,
    // so traits distribution cutoffs should be sorted left-to-right
    // ie smallest packed 8-bit segment should be the leftmost 8 bits
    // TODO: does this mean for N < 32 traits, there should be N-1 distributions?
    mapping(uint8 => uint256) layerTypeToPackedDistributions;

    constructor(
        string memory name,
        string memory symbol,
        address vrfCoordinatorAddress,
        uint240 maxNumSets,
        uint8 numTokensPerSet,
        uint64 subscriptionId
    )
        BatchVRFConsumer(
            name,
            symbol,
            vrfCoordinatorAddress,
            maxNumSets,
            numTokensPerSet,
            subscriptionId
        )
    {}

    /////////////
    // SETTERS //
    /////////////

    /**
     * @notice Set the probability distribution for up to 32 different layer traitIds
     * @param layerType layer type to set distribution for
     * @param distribution a uint256 comprised of sorted, packed bytes
     *  that will be compared against a random byte to determine the layerId
     *  for a given tokenId
     */
    function setLayerTypeDistribution(uint8 layerType, uint256 distribution)
        public
        virtual
        onlyOwner
    {
        _setLayerTypeDistribution(layerType, distribution);
    }

    /**
     * @notice Set layer type distributions for multiple layer types
     * @param layerTypes layer types to set distribution for
     * @param distributions an array of uint256s comprised of sorted, packed bytes
     *  that will be compared against a random byte to determine the layerId
     *  for a given tokenId
     */
    function setLayerTypeDistributions(
        uint8[] memory layerTypes,
        uint256[] memory distributions
    ) public virtual onlyOwner {
        for (uint8 i = 0; i < layerTypes.length; i++) {
            _setLayerTypeDistribution(layerTypes[i], distributions[i]);
        }
    }

    /**
     * @notice calculate the 8-bit seed for a layer by hashing the packedBatchRandomness, tokenId, and layerType together
     * and truncating to 8 bits
     * @param tokenId tokenId to get seed for
     * @param layerType layer type to get seed for
     * @param seed packedBatchRandomness
     * @return layerSeed - 8-bit seed for the given tokenId and layerType
     */
    function getLayerSeed(
        uint256 tokenId,
        uint8 layerType,
        bytes32 seed
    ) internal pure returns (uint8 layerSeed) {
        /// @solidity memory-safe-assembly
        assembly {
            // store seed in first slot of scratch memory
            mstore(0x00, seed)
            // pack tokenId and layerType into one 32-byte slot by shifting tokenId to the left 1 byte
            // tokenIds are sequential and MAX_NUM_SETS * NUM_TOKENS_PER_SET is guaranteed to be < 2**248
            let combinedIdType := or(shl(8, tokenId), layerType)
            mstore(0x20, combinedIdType)
            layerSeed := keccak256(0x00, 0x40)
        }
    }

    /**
     * @notice Determine layer type by its token ID
     */
    function getLayerType(uint256 tokenId)
        public
        view
        virtual
        returns (uint8 layerType);

    /**
     * @notice Get the layerId for a given tokenId by hashing tokenId with its layer type and random seed,
     * and then comparing the final byte against the appropriate distributions
     */
    function getLayerId(uint256 tokenId) public view virtual returns (uint256) {
        return getLayerId(tokenId, getRandomnessForTokenId(tokenId));
    }

    /**
     * @dev perform fewer SLOADs by passing seed as parameter
     */
    function getLayerId(uint256 tokenId, bytes32 seed)
        internal
        view
        virtual
        returns (uint256)
    {
        uint8 layerType = getLayerType(tokenId);
        uint256 layerSeed = getLayerSeed(tokenId, layerType, seed);
        uint256 distributions = layerTypeToPackedDistributions[layerType];
        return getLayerId(layerType, layerSeed, distributions);
    }

    /**
     * @notice calculate the layerId for a given layerType, seed, and distributions.
     * @param layerType of layer
     * @param layerSeed uint256 random seed for layer (in practice will be truncated to 8 bits)
     * @param distributions uint256 packed distributions of layerIds
     * @return layerId limited to 8 bits
     *
     * @dev If the last packed byte is <255, any seed larger than the last packed byte
     *      will be assigned to the index after the last packed byte, unless the last
     *      packed byte is index 31, in which case, it will default to 31.
     *      LayerId is calculated like: index + 1 + 32 * layerType
     *
     * examples:
     * LayerSeed: 0x00
     * Distributions: [01 02 03 04 05 06 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00]
     * Calculated index: 0 (LayerId: 0 + 1 + 32 * layerType)
     *
     * LayerSeed: 0x01
     * Distributions: [01 02 03 04 05 06 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00]
     * Calculated index: 1 (LayerId: 1 + 1 + 32 * layerType)
     *
     * LayerSeed: 0xFF
     * Distributions: [01 02 03 04 05 06 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00]
     * Calculated index: 7 (LayerId: 7 + 1 + 32 * layerType)
     *
     * LayerSeed: 0xFF
     * Distributions: [01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f 20]
     * Calculated index: 31 (LayerId: 31 + 1 + 32 * layerType)
     */
    function getLayerId(
        uint8 layerType,
        uint256 layerSeed,
        uint256 distributions
    ) internal pure returns (uint256 layerId) {
        /// @solidity memory-safe-assembly
        assembly {
            function revertWithBadDistributions() {
                mstore(0, BAD_DISTRIBUTIONS_SIGNATURE)
                revert(0, 4)
            }

            // declare i outside of loop in case final distribution val is less than seed
            let i
            // iterate over distribution values until we find one that our layer seed is less than
            for {

            } lt(i, 32) {
                i := add(1, i)
            } {
                let dist := byte(i, distributions)
                if iszero(dist) {
                    if gt(i, 0) {
                        // if we've reached end of distributions, check layer type != 7
                        // otherwise if layerSeed is less than the last distribution,
                        // the layerId calculation will evaluate to 256 (overflow)
                        if eq(i, 31) {
                            if eq(layerType, 7) {
                                revertWithBadDistributions()
                            }
                        }
                        // if distribution is 0, and it's not the first, we've reached the end of the list
                        // return i + 1 + 32 * layerType
                        layerId := add(add(1, i), shl(5, layerType))
                        break
                    }
                    // first element should never be 0; distributions are invalid
                    revertWithBadDistributions()
                }
                if lt(layerSeed, dist) {
                    // if i is 31 here, math will overflow here if layerType == 7
                    // 31 + 1 + 32 * 7 = 256, which is too large for a uint8
                    if and(eq(i, 31), eq(layerType, 7)) {
                        revertWithBadDistributions()
                    }

                    // layerIds are 1-indexed, so add 1 to i
                    layerId := add(add(1, i), shl(5, layerType))
                    break
                }
            }
            // if i is 32, we've reached the end of the list and should default to the last id
            if eq(i, 32) {
                // math will overflow here if layerType == 7
                // 32 + 32 * 7 = 256, which is too large for a uint8
                if eq(layerType, 7) {
                    revertWithBadDistributions()
                }
                // return previous layerId
                layerId := add(i, shl(5, layerType))
            }
        }
    }

    function _setLayerTypeDistribution(uint8 layerType, uint256 distribution)
        internal
    {
        if (layerType > 7) {
            revert InvalidLayerType();
        }
        layerTypeToPackedDistributions[layerType] = distribution;
    }
}
