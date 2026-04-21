#include <metal_stdlib>
using namespace metal;

kernel void noiseSuppress(
    device const float *mag        [[ buffer(0) ]],
    device float *noise            [[ buffer(1) ]],
    device float *gain             [[ buffer(2) ]],
    device uchar *vad              [[ buffer(3) ]],
    uint id [[ thread_position_in_grid ]]
) {
    float m = mag[id];
    float n = noise[id];

    // -------------------------
    // 🧠 noise tracking
    // -------------------------
    noise[id] = n * 0.98 + m * 0.02;

    // -------------------------
    // 🧠 SNR + Wiener
    // -------------------------
    float snr = m / (noise[id] + 1e-6);
    float g = snr / (1.0 + snr);

    // -------------------------
    // 🧠 VAD (energy gate)
    // -------------------------
    uchar speech = (m > 0.0001) ? 1 : 0;
    vad[id] = speech;

    if (speech == 0) {
        g *= 0.1;
    }

    gain[id] = g;
}