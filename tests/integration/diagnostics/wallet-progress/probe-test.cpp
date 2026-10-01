#include "numeric-progress.h"
#include <cassert>
#include <limits>

int main() {
  wallet_numeric::limiter limit;
  assert(!limit.accept(5, 0));
  assert(limit.accept(0, 0));
  assert(!limit.accept(0, 1));
  assert(limit.accept(1, 1));
  assert(limit.accept(2, 2));
  assert(!limit.accept(3, 16));
  assert(!limit.accept(2, 1));
  assert(limit.accept(3, 17));
  assert(limit.accept(4, 17));
  assert(!limit.accept(4, 18));
  for (unsigned i = limit.emitted; i < 120; ++i) assert(limit.accept(2, 17 + i * 15));
  assert(!limit.accept(2, 100000));
  // Opaque secret-bearing objects cannot enter the numeric-only emitter interface.
  const char* address = "secret-address";
  const char* key = "secret-key";
  const char* payment = "secret-payment-id-and-amount";
  (void)address; (void)key; (void)payment;
  wallet_numeric::emit(2, 3774000);
  wallet_numeric::emit(3, std::numeric_limits<uint64_t>::max());
}
