// Job-owned probe: numeric values only, independent of native log categories.
#pragma once
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <mutex>

namespace wallet_numeric {
struct limiter {
  unsigned emitted = 0;
  unsigned stages = 0;
  uint64_t last_progress = 0;
  bool progressed = false;

  bool accept(unsigned kind, uint64_t seconds) {
    if (kind > 4 || emitted >= 120) return false;
    if (kind == 2 || kind == 3) {
      if (progressed && (seconds < last_progress || seconds - last_progress < 15)) return false;
      progressed = true;
      last_progress = seconds;
    } else {
      const unsigned bit = 1u << kind;
      if (stages & bit) return false;
      stages |= bit;
    }
    ++emitted;
    return true;
  }
};

inline void emit(unsigned kind, uint64_t count) {
  std::fprintf(stderr, "wallet_numeric_progress kind=%u count=%llu\n",
               kind, static_cast<unsigned long long>(count));
}

inline void sample(unsigned kind, uint64_t count) {
  static limiter limit;
  static std::mutex mutex;
  const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
  std::lock_guard<std::mutex> lock(mutex);
  if (limit.accept(kind, static_cast<uint64_t>(seconds))) emit(kind, count);
}
} // namespace wallet_numeric
