require "yaml"

module CombinePDF
  # Lit un fichier `.combine-pdf.yml` et le transforme en
  # `Config`. Tout le YAML passe par le parseur standard SAUF la
  # section `files:` qui est extraite ligne-par-ligne pour préserver
  # commentaires et titres inline lors d'un futur `--refresh`.
  module ConfigLoader
    extend self

    # Charge un fichier de config depuis disque.
    def load(path : String) : Config
      raw = File.read(path)
      load_string(raw)
    end

    # Charge depuis une chaîne (utile pour tests).
    def load_string(raw : String) : Config
      data = YAML.parse(raw)

      Config.new(
        output: parse_str(data["output"]?, "output.pdf"),
        title: parse_str(data["title"]?, ""),
        author: parse_str(data["author"]?, ""),
        paper_size: parse_str(data["paper_size"]?, "a4"),
        duplex: parse_bool(data["duplex"]?, false),
        cover: parse_cover(data["cover"]?),
        numbering: parse_numbering(data["numbering"]?),
        toc: parse_toc(data["toc"]?),
        watermark: parse_watermark(data["watermark"]?),
        encrypt: parse_encrypt(data["encrypt"]?),
        input_password: parse_str(data["input_password"]?, ""),
        files: parse_files_textually(raw),
      )
    end

    # ──────────────────────────────────────────────────────────────
    # Helpers de lecture YAML tolérants
    # ──────────────────────────────────────────────────────────────

    private def parse_str(node : YAML::Any?, default : String) : String
      return default unless node
      node.as_s? || default
    end

    private def parse_bool(node : YAML::Any?, default : Bool) : Bool
      return default unless node
      val = node.as_bool?
      val.nil? ? default : val
    end

    private def parse_int(node : YAML::Any?, default : Int32) : Int32
      return default unless node
      node.as_i? || default
    end

    # Accepte int et float dans le YAML.
    private def parse_float(node : YAML::Any?, default : Float64) : Float64
      return default unless node
      if v = node.as_f?
        v
      elsif v = node.as_i?
        v.to_f
      else
        default
      end
    end

    private def parse_int_array(node : YAML::Any?) : Array(Int32)
      return [] of Int32 unless node
      arr = node.as_a?
      return [] of Int32 unless arr
      arr.compact_map(&.as_i?)
    end

    # Accepte deux formats :
    # * "#RRGGBB"      — hexa
    # * "R,G,B"        — composantes 0.0-1.0 séparées par virgules
    private def parse_color(
      node : YAML::Any?,
      default : Tuple(Float64, Float64, Float64),
    ) : Tuple(Float64, Float64, Float64)
      return default unless node
      str = node.as_s?
      return default unless str
      str = str.strip
      if str.starts_with?("#") && str.size == 7
        r = str[1, 2].to_i(16) / 255.0
        g = str[3, 2].to_i(16) / 255.0
        b = str[5, 2].to_i(16) / 255.0
        {r, g, b}
      else
        parts = str.split(",").map(&.strip.to_f?)
        if parts.size == 3 && parts.all?
          {parts[0].not_nil!, parts[1].not_nil!, parts[2].not_nil!}
        else
          default
        end
      end
    end

    # ──────────────────────────────────────────────────────────────
    # Sections principales
    # ──────────────────────────────────────────────────────────────

    private def parse_cover(node : YAML::Any?) : Config::Cover
      return Config::Cover.new unless node
      Config::Cover.new(
        mode: parse_str(node["mode"]?, "none"),
        front: node["front"]?.try(&.as_s?),
        back: node["back"]?.try(&.as_s?),
        include_in_numbering: parse_bool(node["include_in_numbering"]?, false),
      )
    end

    private def parse_numbering(node : YAML::Any?) : Config::Numbering
      return Config::Numbering.new unless node
      Config::Numbering.new(
        enabled: parse_bool(node["enabled"]?, true),
        global: parse_layer(node["global"]?, Config::Numbering::Layer.global_default),
        partition: parse_layer(node["partition"]?, Config::Numbering::Layer.partition_default),
        header: node["header"]?.try { |n| parse_layer(n, Config::Numbering::Layer.header_default) },
        skip_pages: parse_int_array(node["skip_pages"]?),
      )
    end

    private def parse_layer(
      node : YAML::Any?,
      default : Config::Numbering::Layer,
    ) : Config::Numbering::Layer
      return default unless node
      Config::Numbering::Layer.new(
        enabled: parse_bool(node["enabled"]?, default.enabled),
        format: parse_str(node["format"]?, default.format),
        style: parse_str(node["style"]?, default.style),
        position: parse_str(node["position"]?, default.position),
        font_size: parse_float(node["font_size"]?, default.font_size),
        color: parse_color(node["color"]?, default.color),
        margin: parse_float(node["margin"]?, default.margin),
        bold: parse_bool(node["bold"]?, default.bold),
        italic: parse_bool(node["italic"]?, default.italic),
        hide_when_single: parse_bool(node["hide_when_single"]?, default.hide_when_single),
      )
    end

    private def parse_toc(node : YAML::Any?) : Config::Toc?
      return unless node
      Config::Toc.new(
        bookmarks: parse_bool(node["bookmarks"]?, true),
        page: parse_toc_page(node["page"]?),
      )
    end

    private def parse_toc_page(node : YAML::Any?) : Config::Toc::Page?
      return unless node
      enabled = parse_bool(node["enabled"]?, true)
      return unless enabled
      Config::Toc::Page.new(
        enabled: true,
        title: parse_str(node["title"]?, ""),
        subtitle: parse_str(node["subtitle"]?, "Sommaire"),
        show_author: parse_bool(node["show_author"]?, true),
        leader_dots: parse_bool(node["leader_dots"]?, true),
        title_font_size: parse_float(node["title_font_size"]?, 24.0),
        subtitle_font_size: parse_float(node["subtitle_font_size"]?, 16.0),
        entry_font_size: parse_float(node["entry_font_size"]?, 11.0),
        paper_size: parse_str(node["paper_size"]?, ""),
      )
    end

    # Lit la section `encrypt:` du YAML. Si absente, renvoie `nil`
    # (pas de chiffrement). Les mots de passe peuvent rester vides
    # dans le YAML — ils seront fournis en CLI ou via env vars.
    private def parse_encrypt(node : YAML::Any?) : Config::Encrypt?
      return unless node

      # `enabled: false` désactive explicitement même si le bloc est
      # présent (commute facile pour des envs CI/CD).
      enabled = parse_bool(node["enabled"]?, true)
      return unless enabled

      perms_node = node["permissions"]?
      perms = if perms_node
                arr = perms_node.as_a?
                if arr
                  arr.compact_map(&.as_s?)
                end
              end

      Config::Encrypt.new(
        level: parse_str(node["level"]?, "aes_256"),
        user_password: parse_str(node["user_password"]?, ""),
        owner_password: node["owner_password"]?.try(&.as_s?),
        permissions: perms,
        encrypt_metadata: parse_bool(node["encrypt_metadata"]?, true),
      )
    end

    private def parse_watermark(node : YAML::Any?) : Config::Watermark?
      return unless node
      text = parse_str(node["text"]?, "")
      return if text.empty?
      Config::Watermark.new(
        text: text,
        style: parse_str(node["style"]?, "diagonal"),
        font_size: parse_int(node["font_size"]?, 48),
        color: parse_color(node["color"]?, {0.8, 0.8, 0.8}),
        opacity: parse_float(node["opacity"]?, 0.15),
        rotation: parse_float(node["rotation"]?, 45.0),
      )
    end

    # ──────────────────────────────────────────────────────────────
    # Section `files:` — parsing ligne-par-ligne (préserve commentaires)
    # ──────────────────────────────────────────────────────────────

    # Stratégie : on cherche la ligne `files:` au plus haut niveau du
    # fichier (indentation 0). On parcourt ensuite les lignes
    # suivantes. Une ligne fait partie du tableau si :
    # * elle commence par `- ` (entrée active)
    # * elle commence par `# - ` ou `#- ` (entrée commentée = exclue)
    # On s'arrête à la première ligne non-vide, non-commentaire, qui
    # n'a pas la forme d'une entrée de tableau (= début de la section
    # suivante du YAML).
    def parse_files_textually(raw : String) : Array(Config::FileEntry)
      lines = raw.lines
      files_idx = lines.index(&.starts_with?("files:"))
      return [] of Config::FileEntry unless files_idx

      entries = [] of Config::FileEntry
      idx = files_idx + 1
      while idx < lines.size
        line = lines[idx].chomp
        stripped = line.strip

        if stripped.empty?
          idx += 1
          next
        end

        # Entrée active : `  - foo.pdf` ou `  - foo.pdf: "Titre"`
        # ou inline mapping `- {path: foo.pdf, password: "x"}`
        if md = line.match(/^\s*-\s+(.+)$/)
          path, title, password = parse_entry_body(md[1])
          entries << Config::FileEntry.new(path: path, title: title, excluded: false, password: password)
          idx += 1
          next
        end

        # Entrée commentée : `  # - foo.pdf` ou `# - foo.pdf: "Titre"`
        if md = line.match(/^\s*#\s*-\s+(.+)$/)
          path, title, password = parse_entry_body(md[1])
          # Ne pas confondre avec un commentaire libre qui contient un
          # tiret. Heuristique : `path` doit ressembler à un nom de
          # fichier (extension ou contient `/` ou `.`).
          if looks_like_path?(path)
            entries << Config::FileEntry.new(path: path, title: title, excluded: true, password: password)
          end
          idx += 1
          next
        end

        # Commentaire libre (#sans entrée) → on saute, on reste dans
        # le bloc.
        if stripped.starts_with?("#")
          idx += 1
          next
        end

        # Toute autre ligne non-indentée = début de la section suivante.
        break
      end

      entries
    end

    # Décompose le corps d'une entrée du tableau `files:` en
    # `{path, title, password}`.
    #
    # Trois formes acceptées :
    #
    # ```
    # - foo.pdf                                    # path nu
    # - foo.pdf: "Titre"                           # path + titre
    # - {path: foo.pdf, title: "T", password: "p"} # inline mapping YAML
    # ```
    #
    # L'inline mapping accepte plusieurs alias pour la lisibilité :
    # `path | name | file`, `title | label`, `password | pass | pwd`.
    #
    # Si le chemin lui-même est entre guillemets (utile pour les noms
    # à espaces ou caractères spéciaux), on les retire — comportement
    # cohérent avec le parseur YAML standard.
    private def parse_entry_body(body : String) : Tuple(String, String?, String?)
      body = body.rstrip

      # Forme inline mapping `{path: x, title: "Y", password: "Z"}`.
      # Délégué au parseur YAML standard pour gérer guillemets,
      # échappements, types, etc.
      if body.starts_with?('{') && body.ends_with?('}')
        return parse_inline_mapping(body)
      end

      # Détecte un chemin cité : `"..."` ou `'...'` éventuellement
      # suivi de `: titre`.
      if body.starts_with?('"') || body.starts_with?('\'')
        quote = body[0]
        # Cherche le guillemet fermant correspondant
        i = 1
        while i < body.size
          break if body[i] == quote
          i += 1
        end
        if i < body.size
          path = body[1, i - 1]
          rest = body[(i + 1)..].strip
          if rest.starts_with?(':')
            title_raw = rest[1..].strip
            title_raw = strip_quotes(title_raw)
            return {path, title_raw.empty? ? nil : title_raw, nil}
          end
          return {path, nil, nil}
        end
      end

      # Cas non-cité : on cherche le premier `:` (le path n'en
      # contient pas en pratique).
      if i = body.index(':')
        path = body[0, i].strip
        rest = body[(i + 1)..].strip
        rest = strip_quotes(rest)
        {path, rest.empty? ? nil : rest, nil}
      else
        {body.strip, nil, nil}
      end
    end

    # Parse une entrée inline-mapping `{path: ..., title: ..., password: ...}`
    # en s'appuyant sur le parseur YAML standard. Tolérant aux alias :
    # `path | name | file`, `title | label`, `password | pass | pwd`.
    #
    # Lève `Exception` (avec message clair) si la chaîne n'est pas un
    # mapping YAML valide ou si `path` est absent.
    private def parse_inline_mapping(body : String) : Tuple(String, String?, String?)
      data = YAML.parse(body)
      mapping = data.as_h?
      raise "Entrée inline invalide (mapping YAML attendu) : #{body}" unless mapping

      lookup = ->(keys : Array(String)) {
        keys.each do |k|
          if v = mapping[YAML::Any.new(k)]?
            s = v.as_s?
            return s if s
          end
        end
        nil.as(String?)
      }

      path = lookup.call(["path", "name", "file"])
      raise "Entrée inline sans `path` (alias acceptés : `name`, `file`) : #{body}" if path.nil? || path.empty?

      title = lookup.call(["title", "label"])
      password = lookup.call(["password", "pass", "pwd"])

      {path, title, password}
    end

    private def strip_quotes(s : String) : String
      if s.size >= 2
        first = s[0]
        last = s[-1]
        if (first == '"' && last == '"') || (first == '\'' && last == '\'')
          return s[1..-2]
        end
      end
      s
    end

    private def looks_like_path?(s : String) : Bool
      s.includes?('/') || s.includes?('.')
    end
  end
end
