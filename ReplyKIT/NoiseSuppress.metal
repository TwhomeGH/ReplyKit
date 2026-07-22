#include <metal_stdlib>
using namespace metal;

struct NoiseSuppressParams {
    float noiseAlpha;       // noise estimate smoothing (0.98)
    float noiseBeta;        // noise update weight (0.02)
    float vadThreshold;     // VAD energy threshold
    float minGain;          // minimum gain floor
    uint frameSize;         // number of bins
};

kernel void noiseSuppress(
    device const float *magnitude   [[ buffer(0) ]],
    device float *noiseEstimate     [[ buffer(1) ]],
    device float *gain              [[ buffer(2) ]],
    device float *real              [[ buffer(3) ]],
    device float *imag              [[ buffer(4) ]],
    constant NoiseSuppressParams& params [[ buffer(5) ]],
    uint id                         [[ thread_position_in_grid ]]
) {
    if (id >= params.frameSize) return;

    float mag = magnitude[id];
    float noise = noiseEstimate[id];

    // noise tracking (smooth update)
    noise = noise * params.noiseAlpha + mag * params.noiseBeta;
    noiseEstimate[id] = noise;

    // SNR
    float snr = mag / (noise + 1e-10f);

    // Wiener filter gain
    float g = snr / (1.0f + snr);

    // VAD: use select() to avoid thread divergence
    float speechScale = select(0.1f, 1.0f, mag > params.vadThreshold);
    g *= speechScale;

    // floor
    g = max(g, params.minGain);

    gain[id] = g;

    // apply gain to real & imag
    real[id] = real[id] * g;
    imag[id] = imag[id] * g;
}
