// Replacement global allocation functions that count calls on an armed thread. Test-only.

#include "duette_alloc_counter.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <new>

namespace {

thread_local bool t_armed = false;
thread_local std::uint64_t t_calls = 0;

void note() noexcept {
  if (t_armed) ++t_calls;
}

void* allocate(std::size_t size) {
  note();
  void* p = std::malloc(size != 0 ? size : 1);
  if (p == nullptr) throw std::bad_alloc();
  return p;
}

void* allocateAligned(std::size_t size, std::size_t alignment) {
  note();
  if (alignment < sizeof(void*)) alignment = sizeof(void*);
  void* p = nullptr;
  if (posix_memalign(&p, alignment, size != 0 ? size : 1) != 0) throw std::bad_alloc();
  return p;
}

int* volatile g_probe = nullptr;

}  // namespace

void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept {
  note();
  return std::malloc(size != 0 ? size : 1);
}
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept {
  note();
  return std::malloc(size != 0 ? size : 1);
}
void* operator new(std::size_t size, std::align_val_t alignment) {
  return allocateAligned(size, static_cast<std::size_t>(alignment));
}
void* operator new[](std::size_t size, std::align_val_t alignment) {
  return allocateAligned(size, static_cast<std::size_t>(alignment));
}
void* operator new(std::size_t size, std::align_val_t alignment, const std::nothrow_t&) noexcept {
  try {
    return allocateAligned(size, static_cast<std::size_t>(alignment));
  } catch (...) {
    return nullptr;
  }
}
void* operator new[](std::size_t size, std::align_val_t alignment, const std::nothrow_t&) noexcept {
  try {
    return allocateAligned(size, static_cast<std::size_t>(alignment));
  } catch (...) {
    return nullptr;
  }
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete(void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::align_val_t) noexcept { std::free(p); }
void operator delete(void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t, std::align_val_t) noexcept { std::free(p); }
void operator delete(void* p, std::align_val_t, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete[](void* p, std::align_val_t, const std::nothrow_t&) noexcept { std::free(p); }

extern "C" {

void duette_alloc_counter_arm(void) {
  t_calls = 0;
  t_armed = true;
}

uint64_t duette_alloc_counter_disarm(void) {
  t_armed = false;
  return t_calls;
}

void duette_alloc_counter_probe(void) {
  g_probe = new int(1);
  delete g_probe;
  g_probe = nullptr;
}

}  // extern "C"
