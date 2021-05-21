#version 150

const float PI = 3.141592654;
const float EPSILON = 0.00001;
const int MAX_STEPS = 100;
const int MAX_GLOBAL_ILLUMINATION_STEPS = 10;
const int MAX_GLOBAL_ILLUMINATION_BOUNCES = 3;
const int MAX_REFLECTION_BOUNCES = 10;
const vec3 SUN_COLOR = 1.0 * vec3(1.0, 0.95, 0.8);
const vec3 SKY_COLOR = 2.0 * vec3(0.2, 0.35, 0.5);
const float MAX_EMISSION_STRENGTH = 5;
// I'm targeting anything beyond 1024x768, without the taskbar, that let's us use 1024x705 pixels
// This should just barely fit 8, 88 deep layers vertically (8 * 88 + 1 control line = 705)
// I want to keep the stored layers square, therefore I only use 88 * 11 = 968 pixels horizontally
const vec2 VOXEL_STORAGE_RESOLUTION = vec2(1024, 705);
const float LAYER_SIZE = 88;
const vec2 STORAGE_DIMENSIONS = vec2(11, 8);

#define GAMMA_CORRECTION 2.2

uniform sampler2D DiffuseSampler;
uniform sampler2D DiffuseDepthSampler;
uniform sampler2D TranslucentSampler;
uniform sampler2D TranslucentDepthSampler;
uniform sampler2D ItemEntitySampler;
uniform sampler2D ItemEntityDepthSampler;
uniform sampler2D ParticlesSampler;
uniform sampler2D ParticlesDepthSampler;
uniform sampler2D WeatherSampler;
uniform sampler2D WeatherDepthSampler;
uniform sampler2D CloudsSampler;
uniform sampler2D CloudsDepthSampler;
uniform sampler2D AtlasSampler;
uniform sampler2D SteveSampler;
//uniform sampler2D PreviousFrameSampler;
uniform vec2 OutSize;
uniform float Time;

in vec2 texCoord;
in vec2 oneTexel;
in vec3 sunDir;
in mat4 projMat;
in mat4 modelViewMat;
in mat4 projInv;
in vec3 chunkOffset;
in vec3 rayDir;
in vec3 facingDirection;
in float near;
in float far;

out vec4 fragColor;

struct Ray {
// Index of the block the ray is in.
    vec3 currentBlock;
// Position of the ray inside the block.
    vec3 blockPosition;
// The direction of the ray
    vec3 direction;
};

struct BlockData {
    int type;
    vec2 blockTexCoord;
    vec3 albedo;
    vec3 F0;
    vec4 emission;
    float metallicity;
};

struct Hit {
    float traceLength;
    vec3 block;
    vec3 blockPosition;
    vec3 normal;
    BlockData blockData;
    vec2 texCoord;
};

struct BounceHit {
    float traceLength;
    vec3 block;
    vec3 blockPosition;
    vec3 color;
    vec3 normal;
    vec3 finalDirection;
};

// No moj_import here

vec2 pixelToTexCoord(vec2 pixel) {
    return pixel / (VOXEL_STORAGE_RESOLUTION - 1);
}

vec2 blockToPixel(vec3 position) {
    // The block data is split into layers. Each layer is 60x60 blocks and represents a single y height.
    // Therefore the position inside a layer is just the position of the block on the xz plane relative to the player.
    vec2 inLayerPos = position.xz + LAYER_SIZE / 2;
    // There are 60 layers, we store them in an 8x8 area.
    vec2 layerStart = vec2(mod(position.y + LAYER_SIZE / 2, STORAGE_DIMENSIONS.y), floor((position.y + LAYER_SIZE / 2) / STORAGE_DIMENSIONS.y)) * LAYER_SIZE;
    // The 0.5 offset is to read the center of the "pixels", the +1 offset on the y is to not interfere with the control line
    return layerStart + inLayerPos + vec2(0.5, 1.5);
}

int decodeInt(vec3 ivec) {
    ivec *= 255.0;
    int s = int(sign(127.9 - ivec.b));
    return s * (int(ivec.r) + int(ivec.g) * 256 + (int(ivec.b) - 64 + s * 64) * 256 * 256);
}

BlockData getBlock(vec3 rawData, vec2 texCoord) {
    BlockData blockData;
    int data = decodeInt(rawData);

    vec2 blockTexCoord = (vec2(data >> 6, data & 63) + texCoord) / 64;
    blockData.type = 1;
    blockData.blockTexCoord = blockTexCoord;
    blockData.albedo = pow(texture(AtlasSampler, blockTexCoord / 2).rgb, vec3(GAMMA_CORRECTION));
    blockData.F0 = texture(AtlasSampler, blockTexCoord / 2 + vec2(0, 0.5)).rgb;
    blockData.emission = pow(texture(AtlasSampler, blockTexCoord / 2 + vec2(0.5, 0)), vec4(vec3(GAMMA_CORRECTION), 1.0));
    blockData.metallicity = texture(AtlasSampler, blockTexCoord / 2 + 0.5).r;
    return blockData;
}

vec2 getControl(int index, vec2 screenSize) {
    return vec2(floor(screenSize.x / 2.0) + float(index) * 2.0 + 0.5, 0.5) / screenSize;
}

float intersectPlane(vec3 origin, vec3 direction, vec3 normal) {
    return dot(-origin, normal) / dot(direction, normal);
}

// By Inigo Quilez - https://www.shadertoy.com/view/XlXcW4
const uint k = 1103515245U;

vec3 hash(uvec3 x) {
    x = ((x >> 8U) ^ x.yzx) * k;
    x = ((x >> 8U) ^ x.yzx) * k;
    x = ((x >> 8U) ^ x.yzx) * k;

    return vec3(x) * (1.0 / float(0xffffffffU));
}

vec3 randomDirection(vec2 coords, vec3 normal, float seed) {
    uvec3 p = uvec3(coords * 5000, (Time * 32.46432 + seed) * 60);
    vec3 v = hash(p);
    float angle = 2 * PI * v.x;
    float u = 2 * v.y - 1;
    return normalize(normal + vec3(sqrt(1 - u * u) * vec2(cos(angle), sin(angle)), u));
}

vec3 fresnel(vec3 F0, float cosTheta) {
    return F0 + (1 - F0) * pow(max(1 - cosTheta, 0), 5);
}

Hit trace(Ray ray, int maxSteps, bool reflected) {
    float rayLength = 0;
    vec3 signedDirection = sign(ray.direction);
    vec3 steps = (signedDirection * 0.5 + 0.5 - ray.blockPosition) / ray.direction;
    // Cap the amount of steps we take to make sure no ifinite loop happens.
    for (int i = 0; i < maxSteps; i++) {
        // The world is divided into blocks, so we can use a simplified tracing algorithm where we always go to the
        // nearest block boundary. This can be very easily calculated by dividing the signed distance to the six walls
        // of the current block by the signed components of the ray's direction. This way we get the size of the step
        // we need to take to reach a wall in that direction. This could be faster by precomputing 1 divided by the
        // components of the ray's direction, but I'll keep it simple here. Faster algorithms also exist.

        // The steps in each direction:
        float stepLength = min(min(steps.x, steps.y), steps.z);

        ray.blockPosition += stepLength * ray.direction;
        steps -= stepLength;
        rayLength += stepLength;

        // We select the smallest of the steps and update the current block and block position.
        vec3 nextBlock = step(steps, vec3(EPSILON));

        ray.currentBlock += signedDirection * nextBlock;
        ray.blockPosition = mix(ray.blockPosition, step(signedDirection, vec3(0.5)), nextBlock);
        steps += signedDirection / ray.direction * nextBlock;

        // We can now query if there's a block at the current position.
        vec3 rawData = texture(DiffuseSampler, pixelToTexCoord(blockToPixel(ray.currentBlock))).rgb;
        if (any(greaterThan(abs(ray.currentBlock), vec3(LAYER_SIZE / 2 - 1)))) {
            // We're outside of the known world, there will be dragons. Let's stop
            break;
        } else if (3 - EPSILON > rawData.x + rawData.y + rawData.z) {
            // If it's a block (type is non negative), we stop and draw to the screen.
            vec3 normal = -signedDirection * nextBlock;
            vec2 texCoord = mix((vec2(ray.blockPosition.x, 1.0 - ray.blockPosition.y) - 0.5) * vec2(abs(normal.y) + normal.z, 1.0),
                                (vec2(1.0 - ray.blockPosition.z, ray.blockPosition.z) - 0.5) * vec2(normal.x + normal.y), nextBlock.xy) + vec2(0.5);
            BlockData blockData = getBlock(rawData, texCoord);
            return Hit(rayLength, ray.currentBlock, ray.blockPosition, normal, blockData, texCoord);
        } else if (reflected && distance(ray.currentBlock, vec3(-1.0, -2.0, -1.0)) < 1.8 ) {
            vec3 rayActualPos = ray.currentBlock + ray.blockPosition + chunkOffset;
            float steveDistance = intersectPlane(rayActualPos, ray.direction, vec3(facingDirection.x, 1e-5, facingDirection.z));
            vec3 thingHitPos = rayActualPos + ray.direction * steveDistance;
            float nextStepLength = min(min(steps.x, steps.y), steps.z);
            // Let's check whether the ray will intersect a cylinder
            if (abs(2.0 * steveDistance - nextStepLength) < nextStepLength && abs(0.70 + thingHitPos.y) < 1 && length(thingHitPos.xz) < 0.5) {
                Hit hit;
                hit.traceLength = 999;
                hit.texCoord = vec2((length(thingHitPos.xz) + 0.56) * 1.8 / 2, 0.10 - (thingHitPos.y) / 2);

                vec3 thingColor = texture(SteveSampler, hit.texCoord).rgb;
                if (thingColor.x + thingColor.y + thingColor.z > 0) {
                    hit.blockData.albedo = pow(thingColor, vec3(2.2));
                    return hit;
                }
            }
        }
    }
    Hit hit;
    hit.traceLength = -1;
    return hit;
}

vec3 globalIllumination(Hit hit, Ray ray, float traceSeed) {
    vec3 accumulated = vec3(0.0);
    vec3 weight = vec3(1.0);

    Ray sunRay;
    Hit sunlightHit;
    for (int steps = 0; steps < MAX_GLOBAL_ILLUMINATION_BOUNCES; steps++) {
        // After each bounce, change the base color
        weight *= hit.blockData.albedo * (1 - fresnel(hit.blockData.F0, 1 - dot(ray.direction, hit.normal)));

        // Summon rays
        vec3 direction = randomDirection(texCoord, hit.normal, float(steps) * 754.54 + traceSeed);
        vec3 sunDirection = randomDirection(texCoord, sunDir * 100, float(steps) + 823.375 + traceSeed);
        float NdotL = max(dot(sunDir, hit.normal), 0.0);

        ray = Ray(hit.block, hit.blockPosition, direction);
        sunRay = Ray(hit.block, hit.blockPosition, sunDirection);

        // Path tracing
        hit = trace(ray, MAX_STEPS, true);
        sunlightHit = trace(sunRay, MAX_STEPS, true);

        accumulated += hit.blockData.emission.rgb * MAX_EMISSION_STRENGTH * hit.blockData.emission.a * weight;
        accumulated += sqrt(NdotL) * step(sunlightHit.traceLength, EPSILON) * pow(SUN_COLOR, vec3(GAMMA_CORRECTION)) * weight;

        // Didn't hit a block, considered as hitted sky
        if (hit.traceLength < EPSILON) {
            accumulated += pow(SKY_COLOR, vec3(GAMMA_CORRECTION)) * weight;
            break;
        }
    }

    return accumulated;
}

vec3 pathTrace(Ray ray, out float depth) {
    vec3 accumulated = vec3(0.0);
    vec3 weight = vec3(1.0);

    // Get direct world position
    Hit hit = trace(ray, MAX_STEPS, false);
    depth = hit.traceLength + near;

    // Sky
    if (hit.traceLength < EPSILON) {
        depth = far;
        return pow(SKY_COLOR, vec3(GAMMA_CORRECTION));
    }

    // Global Illumination
    accumulated += hit.blockData.emission.rgb * MAX_EMISSION_STRENGTH * hit.blockData.emission.a;
    accumulated += globalIllumination(hit, ray, 31.43);

    // Reflection
    for (int steps = 0; steps < MAX_REFLECTION_BOUNCES; steps++) {
        weight *= fresnel(hit.blockData.F0, 1 - dot(ray.direction, hit.normal));
        if (dot(weight, hit.blockData.F0) < 5e-3) {
            break;
        }

        ray = Ray(hit.block, hit.blockPosition, reflect(ray.direction, hit.normal));
        hit = trace(ray, MAX_STEPS, true);

        if (hit.traceLength < EPSILON) {
            accumulated += pow(SKY_COLOR, vec3(GAMMA_CORRECTION)) * weight;
            break;
        }
        // Global Illumination in reflecton
        accumulated += globalIllumination(hit, ray, 456.56 * (float(steps) + 1)) * weight;
        accumulated += hit.blockData.emission.rgb * MAX_EMISSION_STRENGTH * hit.blockData.emission.a * weight;
    }

    return accumulated;
}

const int NUM_LAYERS = 5;

vec4 color_layers[NUM_LAYERS];
float depth_layers[NUM_LAYERS];
int active_layers = 0;

void try_insert(vec4 color, float depth) {
    if (color.a == 0.0) {
        return;
    }
    color.rgb = pow(color.rgb, vec3(GAMMA_CORRECTION));

    color_layers[active_layers] = color;
    depth_layers[active_layers] = depth;

    int jj = active_layers++;
    int ii = jj - 1;
    while (jj > 0 && depth_layers[jj] > depth_layers[ii]) {
        float depthTemp = depth_layers[ii];
        depth_layers[ii] = depth_layers[jj];
        depth_layers[jj] = depthTemp;

        vec4 colorTemp = color_layers[ii];
        color_layers[ii] = color_layers[jj];
        color_layers[jj] = colorTemp;

        jj = ii--;
    }
}

vec3 blend( vec3 dst, vec4 src ) {
    return (dst * (1.0 - src.a)) + src.rgb;
}

float linearizeDepth(float depth) {
    return (2.0 * near * far) / (far + near - depth * (far - near));
}

// Uchimura 2017, "HDR theory and practice"
// Math: https://www.desmos.com/calculator/gslcdxvipg
// Source: https://www.slideshare.net/nikuque/hdr-theory-and-practicce-jp
vec3 uchimura(vec3 x, float P, float a, float m, float l, float c, float b) {
  float l0 = ((P - m) * l) / a;
  float L0 = m - m / a;
  float L1 = m + (1.0 - m) / a;
  float S0 = m + l0;
  float S1 = m + a * l0;
  float C2 = (a * P) / (P - S1);
  float CP = -C2 / P;

  vec3 w0 = vec3(1.0 - smoothstep(0.0, m, x));
  vec3 w2 = vec3(step(m + l0, x));
  vec3 w1 = vec3(1.0 - w0 - w2);

  vec3 T = vec3(m * pow(x / m, vec3(c)) + b);
  vec3 S = vec3(P - (P - S1) * exp(CP * (x - S0)));
  vec3 L = vec3(m + a * (x - m));

  return T * w0 + L * w1 + S * w2;
}

vec3 uchimura(vec3 x) {
  const float P = 1.0;  // max display brightness
  const float a = 1.0;  // contrast
  const float m = 0.22; // linear section start
  const float l = 0.4;  // linear section length
  const float c = 1.33; // black
  const float b = 0.0;  // pedestal

  return uchimura(x, P, a, m, l, c, b);
}

void main() {
    // Set the pixel to black in case we don'steps hit anything.
    // Define the ray we need to trace. The origin is always 0, since the blockdata is relative to the player.
    Ray ray = Ray(vec3(-1), 1 - chunkOffset, normalize(rayDir));

    float depth;
    // vec3 color = traceReflections(ray, depth);
    vec3 color = pathTrace(ray, depth);

    if (depth < 0) depth = far;

    vec4 position = projMat * modelViewMat * vec4(normalize(ray.direction) * depth, 1);
    float diffuseDepth = linearizeDepth(sqrt(position.z / position.w));

    color_layers[0] = vec4(color, 1);
    depth_layers[0] = diffuseDepth;
    active_layers = 1;

    try_insert(texture(TranslucentSampler, texCoord), linearizeDepth(texture(TranslucentDepthSampler, texCoord).r));
    try_insert(texture(ItemEntitySampler, texCoord), linearizeDepth(texture(ItemEntityDepthSampler, texCoord).r));
    try_insert(texture(CloudsSampler, texCoord), linearizeDepth(texture(CloudsDepthSampler, texCoord).r));
    try_insert(texture(ParticlesSampler, texCoord), linearizeDepth(texture(ParticlesDepthSampler, texCoord).r));

    vec3 texelAccum = color_layers[0].rgb;
    for ( int ii = 1; ii < active_layers; ++ii ) {
        texelAccum = blend(texelAccum, color_layers[ii]);
    }

    texelAccum = uchimura(texelAccum);
    texelAccum = pow(texelAccum, vec3(1.0 / GAMMA_CORRECTION));

    fragColor = vec4(texelAccum.rgb, 1);
}
