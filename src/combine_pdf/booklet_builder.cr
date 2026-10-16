module CombinePDF
  # Exécute une `Config` : assemble les fichiers, applique la
  # numérotation (cover-aware, duplex-aware, multi-positions), pose
  # le filigrane et écrit le PDF de sortie.
  #
  # C'est le moteur de la commande `combine-pdf` (sans
  # sous-commande) qui lit `.combine-pdf.yml` et produit
  # le livret.
  class BookletBuilder
    @config : Config
    @base_dir : String

    # Surcharges optionnelles fournies par la CLI : permettent de
    # passer le mot de passe en ligne de commande sans le mettre
    # dans le YAML (cas typique : YAML versionné, mots de passe
    # secrets). `nil` = on garde la valeur du YAML telle quelle.
    property override_user_password : String? = nil
    property override_owner_password : String? = nil
    property override_encrypt_level : String? = nil
    property override_encrypt_enabled : Bool? = nil
    # Surcharge la liste de permissions du YAML (`encrypt.permissions`).
    # `nil` = on garde les permissions du YAML (ou tout autorisé si
    # le YAML n'en spécifie pas).
    property override_encrypt_permissions : Array(String)? = nil
    # Surcharge le `input_password:` du YAML pour ouvrir les PDFs
    # sources chiffrés. Utile pour les workflows CI/CD qui ne veulent
    # PAS écrire le mot de passe en clair dans le YAML.
    property override_input_password : String? = nil

    # Quand `true` (défaut), les PDFs sources dont l'une des pages
    # porte `/Rotate ≠ 0` sont pré-traités via `qpdf --flatten-rotation`
    # avant l'assemblage. Évite les pages à l'envers dans le livret
    # final quand un scan a été tourné dans Aperçu macOS sans
    # cuisson du contenu.
    property flatten_rotation : Bool = true

    def initialize(@config : Config, @base_dir : String)
    end

    # Charge la config depuis `dir` et construit le livret.
    def self.from_dir(dir : String) : BookletBuilder
      yml = File.join(dir, ConfigInitializer::CONFIG_FILENAME)
      unless File.exists?(yml)
        raise "Aucun fichier #{ConfigInitializer::CONFIG_FILENAME} dans #{dir}. Lancez d'abord `combine-pdf init`."
      end
      new(ConfigLoader.load(yml), dir)
    end

    # Construit le livret. Renvoie le chemin du fichier produit.
    def build : String
      active = @config.files.reject(&.excluded)
      if active.empty?
        raise "Aucun fichier actif dans la liste `files:` du YAML."
      end

      # Vérifier l'existence sur disque
      missing = active.map(&.path).reject { |p| File.exists?(File.join(@base_dir, p)) }
      unless missing.empty?
        raise "Fichiers introuvables dans #{@base_dir} : #{missing.join(", ")}"
      end

      output_path = File.join(@base_dir, @config.output)

      # Validation préalable : tente d'ouvrir ET de matérialiser tous
      # les objets de chaque fichier pour repérer les rares cas où
      # `pdf` n'arrive pas à parser (PDF malformé, encryption non
      # supportée, stream avec en-tête zlib invalide d'un PDF
      # linéarisé Acrobat ancien, etc.).
      #
      # On ne se contente PAS de `page_count` : ouvrir le PDF n'est
      # qu'une lecture du xref, mais les streams ne sont décompressés
      # que lors de la matérialisation. Forcer la résolution de tous
      # les objets attrape les erreurs Zlib/Filter qui surviendraient
      # plus tard pendant la fusion et donneraient un message
      # cryptique sans contexte de fichier.
      bad_files = [] of Tuple(String, String)
      active.each do |entry|
        full = File.join(@base_dir, entry.path)
        begin
          reader = ::PDF::Reader.open(full, password: password_for(entry))
          total_size = reader.@trailer["Size"]?.try(&.as?(::PDF::Objects::Number)).try(&.to_i64.to_i32) || 0
          (1...total_size).each { |id| reader.resolve(::PDF::Objects::Reference.new(id)) }
        rescue ex : ::PDF::EncryptedPdfError
          # Cas spécifique : PDF chiffré (RC4/AES). Message beaucoup
          # plus ciblé que le générique « Invalid header ».
          bad_files << {entry.path, "chiffré — #{ex.message}"}
        rescue ex
          bad_files << {entry.path, ex.message || "erreur inconnue"}
        end
      end
      unless bad_files.empty?
        msg = String.build do |s|
          s << "Fichiers non lisibles :\n"
          bad_files.each do |path, err|
            s << "  - " << path << "\n    → " << err << "\n"
          end
          s << "\nContournements possibles :\n"
          s << "  1. Normaliser le PDF via Ghostscript (recommandé) :\n"
          bad_files.each do |path, _|
            s << "       combine-pdf gs " << path << " -i --backup\n"
          end
          s << "     Réécrit le PDF en place avec une structure standard\n"
          s << "     que le shard arrive à parser. L'original est sauvegardé\n"
          s << "     en .bak. Nécessite `gs` installé.\n"
          s << "\n"
          s << "  2. Ou exclure l'entrée du YAML en la préfixant par `# - `.\n"
          s << "\n"
          s << "  3. Ou (équivalent à #1, sans la sous-commande) :\n"
          s << "       gs -sDEVICE=pdfwrite -dPDFSETTINGS=/default \\\n"
          s << "          -o normalise.pdf -dNOPAUSE -dQUIET -dBATCH \\\n"
          s << "          fichier-cassé.pdf\n"
        end
        raise msg
      end

      # 1) Fusion des PDF dans l'ordre
      tmp_merged = File.tempname("ccp-merged", ".pdf")
      begin
        # On utilise une instance de Merger plutôt que Merger.merge
        # pour pouvoir insérer une page TOC en tête après tous les
        # `add()`. Si la TOC n'est pas activée, le résultat est
        # identique à `Merger.merge`. On itère sur `active` plutôt que
        # sur les paths nus pour pouvoir passer le mot de passe par
        # fichier (`entry.password` ou fallback global).
        merger = Merger.new
        merger.flatten_rotation = @flatten_rotation
        active.each do |entry|
          full = File.join(@base_dir, entry.path)
          merger.add(full, password: password_for(entry))
        end

        if toc = @config.toc.try(&.page)
          insert_toc_page(merger, active, toc)
        end

        merger.save(tmp_merged)

        # 2) Numérotation (cover-aware, duplex-aware)
        tmp_numbered = File.tempname("ccp-numbered", ".pdf")
        begin
          if @config.numbering.enabled
            partitions = active.map { |entry| ::PDF::Reader.open(File.join(@base_dir, entry.path), password: password_for(entry)).page_count }
            toc_pages = (@config.toc.try(&.page).try(&.enabled)) ? 1 : 0
            AdvancedNumberer.new(@config, partitions, toc_pages).apply(tmp_merged, tmp_numbered)
          else
            File.copy(tmp_merged, tmp_numbered)
          end

          # 3) Filigrane (si demandé)
          tmp_watermarked = File.tempname("ccp-watermarked", ".pdf")
          begin
            if wm = @config.watermark
              apply_watermark(tmp_numbered, tmp_watermarked, wm)
            else
              File.copy(tmp_numbered, tmp_watermarked)
            end

            # 4) Métadonnées (title/author) + chiffrement éventuel
            pdf = CombinePDF.load(tmp_watermarked)
            pdf.title = @config.title unless @config.title.empty?
            pdf.author = @config.author unless @config.author.empty?
            apply_encryption_if_requested(pdf)
            pdf.save(output_path)
          ensure
            File.delete(tmp_watermarked) if File.exists?(tmp_watermarked)
          end
        ensure
          File.delete(tmp_numbered) if File.exists?(tmp_numbered)
        end
      ensure
        File.delete(tmp_merged) if File.exists?(tmp_merged)
      end

      output_path
    end

    # Construit les entrées TOC (à partir de la liste de fichiers
    # active et du nombre de pages de chaque fichier), génère le
    # content stream + annotations via TocBuilder, et insère la
    # page TOC en tête du merger.
    private def insert_toc_page(merger : Merger,
                                active : Array(Config::FileEntry),
                                _toc : Config::Toc::Page) : Nil
      # `merger.page_refs` à ce stade contient les références des
      # pages des partitions, dans l'ordre. Pour chaque entrée
      # active, on associe sa première page = la `cumulative + 1`-ième
      # référence du merger.
      entries = [] of TocBuilder::Entry
      cumulative = 0
      active.each do |file_entry|
        full = File.join(@base_dir, file_entry.path)
        partition_pages = ::PDF::Reader.open(full, password: password_for(file_entry)).page_count
        target_ref = merger.page_refs[cumulative]?
        next unless target_ref

        # Numéro affiché : 1-based dans le livret final, en
        # tenant compte du décalage de la TOC (+1 page) et de
        # cover.include_in_numbering.
        displayed = compute_displayed_page_number(cumulative)

        entries << TocBuilder::Entry.new(
          title: file_entry.display_title,
          page_number: displayed,
          target_page_ref: target_ref,
        )
        cumulative += partition_pages
      end

      builder = TocBuilder.new(@config, entries)
      content, annots = builder.build
      merger.insert_toc_page(content, annots, builder.page_width, builder.page_height)
    end

    # Calcule le numéro de page affiché pour une page située à
    # l'index `idx` dans le contenu (0-based, AVANT insertion de la
    # TOC). Tient compte de cover.front_pages et de
    # cover.include_in_numbering.
    private def compute_displayed_page_number(idx : Int32) : Int32
      cover = @config.cover
      front = cover.front_pages
      if cover.include_in_numbering
        # La couverture compte ; la TOC compte aussi (en première
        # position). Donc page 1 = TOC, page 2 = front-cover-1, …
        idx + front + 2
      else
        # Couverture et TOC sautées. Numérotation = idx - front + 1
        # avec un plancher à 1 si la TOC pointe avant la couverture
        # (rare mais possible).
        if idx < front
          1
        else
          idx - front + 1
        end
      end
    end

    # Mot de passe effectif pour ouvrir les PDFs sources chiffrés
    # (mot de passe global, fallback de `password_for`).
    # Précédence : CLI (`override_input_password`) > YAML (`input_password`)
    # > vide.
    private def effective_input_password : String
      @override_input_password || @config.input_password
    end

    # Convertit une liste de noms de permissions (chaînes) en
    # `Array(::PDF::Security::Permission)` pour le passer au shard
    # `pdf`. Tolérant aux noms inconnus (ignorés) et aux raccourcis
    # `none` (vide) et `all` (toutes les permissions).
    private def map_permission_names(names : Array(String)) : Array(::PDF::Security::Permission)
      all = [::PDF::Security::Permission::Print,
             ::PDF::Security::Permission::Copy,
             ::PDF::Security::Permission::Modify,
             ::PDF::Security::Permission::Annotate]
      return [] of ::PDF::Security::Permission if names.size == 1 && names.first.downcase == "none"
      return all if names.size == 1 && names.first.downcase == "all"

      names.compact_map do |name|
        case name.to_s.downcase
        when "print"    then ::PDF::Security::Permission::Print
        when "copy"     then ::PDF::Security::Permission::Copy
        when "modify"   then ::PDF::Security::Permission::Modify
        when "annotate" then ::PDF::Security::Permission::Annotate
        end
      end
    end

    # Mot de passe à utiliser pour ouvrir un fichier source précis.
    # Précédence : `entry.password` (per-file YAML) >
    # `effective_input_password` (global YAML/CLI).
    private def password_for(entry : Config::FileEntry) : String
      entry.password || effective_input_password
    end

    # Applique le chiffrement au PDF si demandé par le YAML ou par
    # une surcharge CLI. Mots de passe :
    # * en CLI (`override_*_password`) : prioritaire — utile quand
    #   on ne veut pas écrire le mot de passe en clair dans le YAML
    #   (ex. YAML versionné).
    # * dans le YAML (`encrypt.user_password` / `encrypt.owner_password`)
    #   sinon.
    private def apply_encryption_if_requested(pdf : CombinePDF::PDF) : Nil
      enc = @config.encrypt
      enabled_override = @override_encrypt_enabled
      return if enabled_override == false
      return if enc.nil? && enabled_override != true

      # Si le YAML n'a pas d'encrypt et qu'on veut activer via CLI :
      # construire une config par défaut.
      enc ||= Config::Encrypt.new(level: @override_encrypt_level || "aes_256")

      level_str = @override_encrypt_level || enc.level
      level_sym = case level_str.downcase
                  when "rc4_128", "rc4-128", "rc4" then :rc4_128
                  when "aes_128", "aes-128"        then :aes_128
                  when "aes_256", "aes-256", "aes" then :aes_256
                  else
                    raise "Niveau de chiffrement inconnu : #{level_str.inspect}"
                  end

      user_pwd = @override_user_password || enc.user_password
      owner_pwd = @override_owner_password || enc.owner_password || user_pwd

      # Permissions : CLI override > YAML > tout autorisé
      effective_perms = if cli_perms = @override_encrypt_permissions
                          map_permission_names(cli_perms)
                        else
                          enc.permissions_for_pdf
                        end

      pdf.encrypt(
        user_password: user_pwd,
        owner_password: owner_pwd,
        level: level_sym,
        permissions: effective_perms,
        encrypt_metadata: enc.encrypt_metadata,
      )
    end

    private def apply_watermark(input : String, output : String, wm : Config::Watermark) : Nil
      # watermark a son propre vocabulaire de styles. On mappe
      # nos chaînes vers ses constantes.
      style = case wm.style
              when "diagonal" then Watermark::Style::Diagonal
              when "tiled"    then Watermark::Style::Tiled
              when "header"   then Watermark::Style::Header
              when "footer"   then Watermark::Style::Footer
              when "center"   then Watermark::Style::Center
              else                 Watermark::Style::Diagonal
              end

      options = Watermark::Options.new(
        font_size: wm.font_size,
        color: wm.color,
        opacity: wm.opacity,
        rotation: wm.rotation,
      )

      Watermark.apply(input, output, wm.text, style, options)
    end
  end
end
