module ShipImages
  # What is kept of an upload: the re-encoded WebP and its facts. Nothing of the original survives.
  Processed = Data.define(:content, :width, :height, :byte_size, :sha256)
end
