### Internal

- CI now builds its reusable `zigapagos` binary for the architecture's baseline CPU instead
  of the build runner's native CPU. A runner with AVX-512 produced an artifact whose
  `compiler_rt.memcpy` executed AVX-512 unconditionally on unrelated downstream runners;
  hosts without that feature raised SIGILL, and a signal on a render worker could leave the
  main thread waiting forever. The artifact gate now rejects host-width YMM/ZMM memcpy code.
