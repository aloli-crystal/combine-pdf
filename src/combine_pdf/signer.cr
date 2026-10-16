module CombinePDF
  # Thin bridge to the ALOLI PDF signing binary (aloli-crystal/pdf-signature),
  # so combine-pdf can sign or verify a freshly assembled document without
  # leaving the tool (the natural last step after `merge` / `assemble`).
  #
  # We shell out rather than depend on pdf-signature as a shard : the two
  # pin incompatible `pdf` versions (combine-pdf on 0.5.x, pdf-signature on
  # 1.x). This mirrors the existing `qpdf` / `gs` shell-out integrations.
  #
  # ## Binary resolution (and the poppler name clash)
  #
  # The ALOLI signer is `pdf-sign` (pd-signature renamed it from `pdfsig`
  # to avoid poppler's identically-named, unrelated tool). Resolution:
  #   1. `$COMBINE_PDF_PDFSIG` — an explicit path to the ALOLI binary
  #      (the reliable, unambiguous choice ; set it in your profile) ;
  #   2. otherwise `pdf-sign` on PATH. Bare `pdfsig` (poppler's) is never
  #      probed, so we can't call the wrong binary.
  #
  # ## Security
  #
  # The passphrase / PIN is forwarded as the *name* of an environment
  # variable (the binary's `-p` / `-P`), never as a value, so no secret
  # appears in this process's or the child's argv.
  module Signer
    # The ALOLI signer is `pdf-sign` (aloli-crystal/pdf-signature ≥ 0.11.0,
    # renamed from `pdfsig` precisely to avoid poppler's tool). Bare
    # `pdfsig` is poppler's and is deliberately NOT probed, so we never
    # call the wrong binary. Use $COMBINE_PDF_PDFSIG to override the path.
    CANDIDATES = %w[pdf-sign]

    # Resolves the ALOLI signing binary, or `nil` if none is found.
    def self.binary : String?
      if explicit = ENV["COMBINE_PDF_PDFSIG"]?
        return explicit unless explicit.empty?
      end
      CANDIDATES.each do |name|
        if path = Process.find_executable(name)
          return path
        end
      end
      nil
    end

    # Forwards `args` verbatim to `<binary> <subcommand>`, inheriting stdio
    # so the user sees the signer's own messages and exit code. Returns that
    # exit code (`0` ok, non-zero = failure / invalid signature), or `2`
    # with a guidance message on stderr if no ALOLI binary is found.
    def self.forward(subcommand : String, args : Array(String)) : Int32
      target = binary
      unless target
        STDERR.puts(
          "Erreur : binaire de signature ALOLI `pdf-sign` introuvable.\n" \
          "  Il est fourni par aloli-crystal/pdf-signature (>= 0.11.0).\n" \
          "  Construisez ce shard puis, au choix :\n" \
          "    • symlinkez son binaire dans le PATH :\n" \
          "        ln -s …/pdf-signature/bin/pdf-sign ~/bin/pdf-sign\n" \
          "    • ou exportez COMBINE_PDF_PDFSIG=…/pdf-signature/bin/pdf-sign"
        )
        return 2
      end
      status = Process.run(
        target,
        [subcommand] + args,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      status.exit_code
    end
  end
end
