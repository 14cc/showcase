"""Compile and exercise the production resolution selector without UIKit."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
start = source.index('    uint64_t pixelBudget =', source.index('static CarPlayDisplayProfile preferred_'))
end = source.index('    CarPlayDisplayProfile profile =', start)
selector = source[start:end]
harness = r'''
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include <float.h>
#include <assert.h>
#define MIN(a,b) ((a)<(b)?(a):(b))
#define MAX(a,b) ((a)>(b)?(a):(b))
static uint64_t select_profile(uint64_t memory, unsigned processors,
    double nativeLong, double nativeShort, bool preferSmooth) {
    double aspect = nativeLong / nativeShort;
    uint16_t framesPerSecond = 60;
''' + selector + r'''
    assert(framesPerSecond == 30);
    assert(bestWidth % 16 == 0 && bestHeight % 16 == 0);
    assert(bestWidth <= nativeLong && bestHeight <= nativeShort);
    assert((uint64_t)bestWidth * bestHeight <= pixelBudget);
    assert(pixelBudget <= 1920ULL * 1080ULL);
    assert(fabs((double)bestWidth / bestHeight - aspect) / aspect < 0.03);
    if (memory == 1024ULL * 1024ULL * 1024ULL && !preferSmooth && nativeLong == 2048)
        assert(bestWidth == 1280 && bestHeight == 960);
    return (uint64_t)bestWidth * bestHeight;
}
int main(void) {
    const double displays[][2] = {{2048,1536}, {2732,2048}, {1920,1080}, {1136,640}, {1024,768}};
    for (unsigned ram = 1; ram <= 8; ram++) {
        for (unsigned cores = 2; cores <= 8; cores += 2) {
            for (unsigned i = 0; i < sizeof displays / sizeof displays[0]; i++) {
                uint64_t memory = (uint64_t)ram * 1024 * 1024 * 1024;
                uint64_t sharp = select_profile(memory, cores, displays[i][0], displays[i][1], false);
                uint64_t smooth = select_profile(memory, cores, displays[i][0], displays[i][1], true);
                assert(sharp >= smooth);
            }
        }
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'check.c').write_text(harness)
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(path / 'check.c'), '-lm', '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
print('PASS: 320 profiles; resolution, aspect, pixel budget, cadence, smooth fallback')
