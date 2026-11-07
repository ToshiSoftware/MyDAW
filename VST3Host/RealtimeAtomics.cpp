// Atomic loads and stores for state shared between the render thread and
// other threads (see Sources/Audio/TrackRenderer.swift). Swift's own atomics
// need macOS 15, and MyDAW targets 13, so the Swift side calls these.

#include <cstdint>

extern "C" {

int64_t MyDAWAtomicLoad64(const int64_t* pointer) {
    return __atomic_load_n(pointer, __ATOMIC_ACQUIRE);
}

void MyDAWAtomicStore64(int64_t* pointer, int64_t value) {
    __atomic_store_n(pointer, value, __ATOMIC_RELEASE);
}

void MyDAWMemoryFence(void) {
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}

}
