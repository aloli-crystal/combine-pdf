require "random/secure"

module CombinePDF
  # ISO-compatible port of `CombinePDF::PDF` from the Ruby gem
  # `combine_pdf` v1.0.31. Wraps the merger state (objects + page
  # references) plus document metadata (title, author).
  #
  # Mirrors the upstream API one-to-one so existing Ruby code
  # examples and documentation translate directly :
  #
  # ```
  # # Ruby (combine_pdf v1.0.31)
  # pdf = CombinePDF.new
  # pdf << CombinePDF.load("a.pdf")
  # pdf << CombinePDF.load("b.pdf")
  # pdf.title = "Recueil"
  # pdf.number_pages
  # pdf.save("out.pdf")
  #
  # # Crystal (this shard)
  # pdf = CombinePDF.new
  # pdf << CombinePDF.load("a.pdf")
  # pdf << CombinePDF.load("b.pdf")
  # pdf.title = "Recueil"
  # pdf.number_pages
  # pdf.save("out.pdf")
  # ```
  #
  # The `Merger` and `Numberer` classes (Crystal-specific helpers
  # introduced in v0.1/v0.2) remain available for users who prefer
  # the functional one-liner style :
  #   `CombinePDF.merge(inputs, output)`
  #   `CombinePDF.number(input, output)`
  #   `CombinePDF.assemble(inputs, output)`
  class PDF
    # Document metadata. Set them before `save` to have them
    # appear in the PDF `/Info` dictionary.
    property title : String? = nil
    property author : String? = nil

    # Internal merger that accumulates pages. Exposed for advanced
    # callers ; most users should go through the high-level methods.
    getter merger : Merger

    # Creates an empty PDF ready to receive pages via `#<<` /
    # `#insert` / `#new_page`.
    def initialize
      @merger = Merger.new
    end

    # Builds a PDF from an existing file. Equivalent to the Ruby
    # gem's `CombinePDF.load(path)`. `password` est forwardé au
    # `Merger#add` quand le fichier est chiffré.
    def self.from_file(path : String, password : String = "") : PDF
      pdf = new
      pdf.merger.add(path, password: password)
      pdf
    end

    # Builds a PDF from raw bytes. Equivalent to the Ruby gem's
    # `CombinePDF.parse(data)`. Internally writes the bytes to a
    # temp file (the underlying `PDF::Reader` only accepts paths
    # for now ; a later refactor could plumb the bytes through).
    def self.from_data(data : Bytes | String) : PDF
      pdf = new
      tmp = File.tempname("ccp-parse", ".pdf")
      begin
        File.write(tmp, data)
        pdf.merger.add(tmp)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      pdf
    end

    # Appends the pages of `other` (file path or another `PDF`) to
    # the end of this PDF. Returns `self` to enable chaining,
    # mirroring Ruby's `<<` semantics.
    #
    # ```
    # pdf << "morceau1.pdf" << "morceau2.pdf"
    # ```
    def <<(other : String) : self
      @merger.add(other)
      self
    end

    # :ditto:
    def <<(other : PDF) : self
      # Materialise the other PDF to a temp file and re-ingest it.
      # Inefficient but correct ; a smarter implementation would
      # merge the mergers' state directly. Left as a v1.0.31.2
      # optimisation.
      tmp = File.tempname("ccp-merge", ".pdf")
      begin
        other.save(tmp)
        @merger.add(tmp)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      self
    end

    # Prepends `other` (file path or another `PDF`) to the
    # beginning of this PDF. Returns `self` for chaining.
    # Mirrors Ruby's `>>` semantics.
    def >>(other : String) : self
      insert(0, other)
    end

    # :ditto:
    def >>(other : PDF) : self
      insert(0, other)
    end

    # Inserts the pages of `other` at position `location` (0-based).
    # `-1` appends at the end (equivalent to `<<`).
    #
    # ```
    # pdf.insert(0, "cover.pdf")     # prepend
    # pdf.insert(-1, "back.pdf")     # append
    # pdf.insert(2, "intermède.pdf") # between current pages 2 and 3
    # ```
    def insert(location : Int32, other : String | PDF) : self
      # Snapshot existing pages, clear, then re-add in the new
      # order. Inefficient for large PDFs but keeps the merger
      # invariants intact (every page ref must point at a
      # registered object, parents recomputed at write time).
      original_refs = @merger.page_refs.dup
      effective_loc = location < 0 ? original_refs.size + location + 1 : location
      effective_loc = effective_loc.clamp(0, original_refs.size)

      before_refs = original_refs[0, effective_loc]
      after_refs = original_refs[effective_loc..]

      # Remember the current size before adding `other`.
      pre_size = @merger.page_refs.size
      case other
      when String then @merger.add(other)
      when PDF
        tmp = File.tempname("ccp-insert", ".pdf")
        begin
          other.save(tmp)
          @merger.add(tmp)
        ensure
          File.delete(tmp) if File.exists?(tmp)
        end
      end
      added_refs = @merger.page_refs[pre_size..]

      # Rebuild the page_refs in the desired order. The objects
      # themselves are already registered ; only the order of refs
      # in the final /Pages tree changes.
      @merger.page_refs.clear
      before_refs.each { |r| @merger.page_refs << r }
      added_refs.each { |r| @merger.page_refs << r }
      after_refs.each { |r| @merger.page_refs << r }
      self
    end

    # Removes the page at `page_index` (0-based) from the document
    # and returns the removed reference. Negative indices count
    # from the end (Ruby convention).
    #
    # NOTE : the underlying objects (page dict, content streams,
    # fonts, …) remain in the merger's object pool — they're just
    # excluded from the final /Pages tree. Cosmetically the output
    # PDF is slightly larger than necessary ; a v1.0.31.2 pass
    # could prune unreferenced objects.
    def remove(page_index : Int32) : ::PDF::Objects::Reference?
      effective = page_index < 0 ? @merger.page_refs.size + page_index : page_index
      return if effective < 0 || effective >= @merger.page_refs.size
      @merger.page_refs.delete_at(effective)
    end

    # Returns the array of page references in the current document
    # order. Each reference identifies a page object inside the
    # internal merger's pool.
    #
    # NOTE : in v1.0.31.1 the returned items are
    # `PDF::Objects::Reference` instances, not full Page wrappers.
    # A `Page` class with the rich Ruby methods (`textbox`,
    # `rotate_left`, `mediabox`, …) is planned for v1.0.31.2+.
    def pages : Array(::PDF::Objects::Reference)
      @merger.page_refs
    end

    # Number of pages in this PDF.
    def page_count : Int32
      @merger.page_refs.size
    end

    # Adds a new blank page at `location` (0-based, `-1` = append,
    # the default). `mediabox` defaults to US Letter
    # `[0, 0, 612.0, 792.0]` to match the Ruby gem.
    #
    # NOTE : v1.0.31.1 only supports the default mediabox via the
    # blank-page generator. Custom dimensions and rich page
    # construction will land in v1.0.31.2.
    def new_page(mediabox : Array(Float64) = [0.0, 0.0, 612.0, 792.0],
                 location : Int32 = -1) : self
      tmp = File.tempname("ccp-blank", ".pdf")
      begin
        doc = ::PDF::Document.new
        doc.page(width: mediabox[2] - mediabox[0],
          height: mediabox[3] - mediabox[1]) do |_page|
          # intentionally empty
        end
        doc.save(tmp)
        if location == -1
          @merger.add(tmp)
        else
          insert(location, tmp)
        end
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      self
    end

    # Adds page numbers to this PDF in place. Same options as
    # `CombinePDF.number` — see `Numberer` and `Options`.
    #
    # In contrast with the module-level helper, this method
    # operates on the in-memory PDF (round-trips through a temp
    # file because the Numberer currently only knows file paths).
    def number_pages(partitions : Array(Int32)? = nil,
                     options : Options = Options.new) : self
      tmp_in = File.tempname("ccp-num-in", ".pdf")
      tmp_out = File.tempname("ccp-num-out", ".pdf")
      begin
        save(tmp_in)
        Numberer.new(options, partitions).apply(tmp_in, tmp_out)
        # Reset the merger and re-ingest the numbered file.
        @merger = Merger.new
        @merger.add(tmp_out)
      ensure
        File.delete(tmp_in) if File.exists?(tmp_in)
        File.delete(tmp_out) if File.exists?(tmp_out)
      end
      self
    end

    # Writes the PDF to disk. `options` is accepted for API
    # parity with the Ruby gem but currently ignored — every save
    # produces an uncompressed flat PDF 1.7. Compression and
    # encryption options are planned for v1.0.31.4.
    def save(file_name : String, options : Hash(Symbol, _) = {} of Symbol => String) : Nil
      apply_metadata
      @merger.save(file_name)
    end

    # Returns the PDF as a byte buffer (without writing to disk).
    # `options` accepted for API parity, currently ignored.
    def to_pdf(options : Hash(Symbol, _) = {} of Symbol => String) : Bytes
      apply_metadata
      io = IO::Memory.new
      @merger.write(io)
      io.to_slice
    end

    # Active le chiffrement du PDF. Au prochain `save`, tous les
    # streams et chaînes indirectes seront chiffrés et un dictionnaire
    # `/Encrypt` sera écrit dans le trailer.
    #
    # ```
    # pdf = CombinePDF.load("input.pdf")
    # pdf.encrypt(
    #   user_password: "secret",
    #   owner_password: "owner",
    #   level: :aes_256,
    #   permissions: [PDF::Security::Permission::Print],
    # )
    # pdf.save("encrypted.pdf")
    # ```
    #
    # Niveau (`level`) :
    # * `:rc4_128` — RC4 128-bit (V=2, R=3). Compatible Acrobat ≥ 5.
    # * `:aes_128` — AES-128 + CryptFilter AESV2 (V=4, R=4). Acrobat ≥ 7.
    # * `:aes_256` — AES-256 (V=5, R=6, PDF 2.0). Acrobat ≥ X. Défaut.
    def encrypt(
      user_password : String = "",
      owner_password : String = "",
      level : Symbol = :aes_256,
      permissions : Array(::PDF::Security::Permission) = [
        ::PDF::Security::Permission::Print,
        ::PDF::Security::Permission::Copy,
        ::PDF::Security::Permission::Modify,
        ::PDF::Security::Permission::Annotate,
      ],
      encrypt_metadata : Bool = true,
    ) : self
      lvl = case level
            when :rc4_128 then ::PDF::Encryption::StandardSecurity::Level::RC4_128
            when :aes_128 then ::PDF::Encryption::StandardSecurity::Level::AES_128
            when :aes_256 then ::PDF::Encryption::StandardSecurity::Level::AES_256
            else
              raise ArgumentError.new("Niveau de chiffrement inconnu : #{level.inspect}")
            end

      # Calcul de /P (permissions) selon § 7.6.3.2.
      perms_value = -1_i32
      perms_value &= ~0b00111100 # bits 3..6 à 0
      permissions.each { |p| perms_value |= p.value }
      perms_value &= ~0b11 # bits 1..2 à 0

      # /ID — 16 octets aléatoires si pas déjà fixés
      @merger.file_id ||= Random::Secure.random_bytes(16)
      id_bytes = @merger.file_id.not_nil!

      @merger.security_handler =
        ::PDF::Encryption::StandardSecurity.build_for_encryption(
          user_password: user_password,
          owner_password: owner_password.empty? ? user_password : owner_password,
          level: lvl,
          permissions: perms_value,
          id: id_bytes,
          encrypt_metadata: encrypt_metadata,
        )
      self
    end

    # Reapplies title/author metadata to the merger before writing.
    # The merger's writer adds a default `/Info` dict ; we override
    # the relevant entries here so user-set values stick.
    private def apply_metadata : Nil
      @merger.metadata_title = @title
      @merger.metadata_author = @author
    end
  end
end
