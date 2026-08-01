### Fixed

- A CLI report no longer overwrites the command's own stderr when both streams are redirected
  to one file (`cmd >f 2>&1`). `explain`, `doctor`, `validate` and `migrate --doctor` built
  their buffered stdout writers with `Io.File.writer`, which writes positionally from an offset
  of its own, so the end-of-command flush landed on top of bytes stderr had already committed —
  silently corrupting the merged output. They now use `writerStreaming`.
