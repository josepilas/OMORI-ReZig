/* The PC build contains JPEG thumbnails/transitions inside .rpgmvp files.
 * Keep this compilation unit JPEG-only; PNG and VP8L use native decoders.
 * stb_image's MIT license is included in stb_image.h. */
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_MAX_DIMENSIONS 16384
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
