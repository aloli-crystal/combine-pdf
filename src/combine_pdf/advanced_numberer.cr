module CombinePDF
  # Moteur de numérotation v1.0.31.2 — refonte de `Numberer` qui prend
  # une `Config` complète et gère :
  #
  # * positions cardinales (top/bottom × left/center/right)
  # * positions duplex-aware (outer/inner) qui alternent par parité
  # * cover (front + back) avec `include_in_numbering: false` qui
  #   décale le démarrage de la numérotation
  # * couches multiples (global + partition + header optionnel)
  # * styles visuels (`plain`, `badge` arrondi)
  # * `skip_pages` 1-based (s'ajoute aux pages cover)
  class AdvancedNumberer
    @config : Config
    @partitions : Array(Int32)
    @toc_pages : Int32

    # `toc_pages` = nombre de pages de TOC insérées en tête (0 ou 1).
    # Ces pages sont JAMAIS numérotées et n'ont pas d'info partition.
    def initialize(@config : Config, @partitions : Array(Int32), @toc_pages : Int32 = 0)
    end

    def apply(input : String, output : String) : Nil
      reader = ::PDF::Reader.open(input)
      total = reader.page_count

      sum = @partitions.sum + @toc_pages
      if sum != total
        raise ArgumentError.new(
          "partitions sum (#{@partitions.sum}) + toc_pages (#{@toc_pages}) does not match the PDF page count (#{total})"
        )
      end

      cover = @config.cover
      front = cover.front_pages
      back = cover.back_pages
      content_total = total - @toc_pages - front - back
      content_total = 0 if content_total < 0

      # Map 0-based page index → infos de partition (n_dans_partition, n_total_partition)
      # Décalé de toc_pages pour que la 1ère partition commence après la TOC.
      page_to_partition = build_page_to_partition_map(total)

      reader.pages.each_with_index do |page, idx|
        page_num_pdf = idx + 1 # 1-based

        # ─── Calcul du numéro affiché
        # Pages TOC : aucune numérotation, aucune partition.
        is_toc = idx < @toc_pages
        # Couvertures : APRÈS la TOC en tête, et AVANT la fin pour
        # le back cover.
        is_front_cover = !is_toc && idx < (@toc_pages + front)
        is_back_cover = idx >= (total - back)
        is_cover = is_front_cover || is_back_cover

        # Numéro global affiché
        if is_toc
          show_global = false
          displayed_global = 0
          displayed_total = content_total
        elsif @config.cover.include_in_numbering
          displayed_global = idx - @toc_pages + 1
          displayed_total = total - @toc_pages
          show_global = true
        else
          if is_cover
            show_global = false
            displayed_global = 0
            displayed_total = content_total
          else
            displayed_global = idx - @toc_pages - front + 1 # 1-based dans le contenu
            displayed_total = content_total
            show_global = true
          end
        end

        # Skip pages (1-based, basé sur la numérotation PDF brute)
        show_global = false if @config.numbering.skip_pages.includes?(page_num_pdf)

        # ─── Construction des couches
        layers = [] of Tuple(Float64, Float64, String, Config::Numbering::Layer, String)

        # Couche globale
        if @config.numbering.global.enabled && show_global
          text = format(@config.numbering.global.format, displayed_global, displayed_total)
          x, y = compute_xy(
            @config.numbering.global,
            page.width, page.height,
            text, page_num_pdf,
          )
          layers << {x, y, text, @config.numbering.global, "global"}
        end

        # Couche partition (jamais sur les pages TOC ni couvertures)
        if @config.numbering.partition.enabled && !is_cover && !is_toc
          if pi = page_to_partition[idx]?
            part_n, part_total = pi
            unless @config.numbering.partition.hide_when_single && part_total <= 1
              text = format(@config.numbering.partition.format, part_n, part_total)
              x, y = compute_xy(
                @config.numbering.partition,
                page.width, page.height,
                text, page_num_pdf,
              )
              layers << {x, y, text, @config.numbering.partition, "partition"}
            end
          end
        end

        # Header (TODO v1.0.31.3 — nécessite le titre par fichier)

        next if layers.empty?

        # CRITIQUE : avant d'écrire un content stream qui référence
        # nos polices `/__CCP_HV*__ X Tf`, on s'assure qu'elles sont
        # déclarées dans le `/Resources /Font` de la page. Sans ça,
        # certains viewers PDF (Preview macOS, mupdf, viewers Web)
        # refusent de tracer le texte parce qu'ils ne savent pas
        # inférer la police standard depuis son nom long.
        needed_fonts = layers.map { |l| l[3] }.uniq
        # Si l'un des textes contient un dingbat Unicode (★ ♥ ✦ ✓ ✗
        # …), on doit AUSSI injecter ZapfDingbats — cf.
        # `render_layer` qui découpe en runs.
        needs_zapf = layers.any? do |l|
          l[2].each_char.any? { |ch| ZapfDingbats.dingbat?(ch) }
        end
        ensure_fonts_in_page_resources(reader, page, needed_fonts, needs_zapf)

        # Calcule l'inverse de la CTM cumulée des content streams
        # existants — neutralise un Y-flip ou un scale hérité (par ex.
        # `0.75 0 0 -0.75 0 841.92 cm` au début du stream amont) qui
        # ferait sortir notre overlay à l'envers et à la mauvaise taille.
        cm_inv = cm_inverse_for_prior_streams(page.content_streams)

        stream = build_stream(layers, cm_inv)
        page.add_content_stream(stream) unless stream.empty?
      end

      reader.save(output)
    end

    # Garantit que les polices référencées par les couches `layers`
    # sont déclarées dans `/Resources /Font` de la page. Crée le
    # dictionnaire de Resources et/ou de Font si absents ; copie
    # les dictionnaires partagés via référence indirecte avant de
    # les modifier (pour ne pas contaminer d'autres pages).
    #
    # `needs_zapf` : `true` si l'un des textes contient un dingbat
    # Unicode → on déclare aussi ZapfDingbats sous la clé
    # `/__CCP_ZD__`. ZapfDingbats utilise son propre encoding
    # (StandardEncoding par défaut, pas WinAnsi) — chaque dingbat
    # est référencé par son codepoint propre dans la police.
    private def ensure_fonts_in_page_resources(
      reader : ::PDF::Reader, page : ::PDF::ReaderPage,
      layers : Array(Config::Numbering::Layer),
      needs_zapf : Bool = false,
    ) : Nil
      page_dict = page.page_dict

      resources = unshare_dict(reader, page_dict["Resources"]?)
      font = unshare_dict(reader, resources["Font"]?)

      layers.each do |layer|
        key = layer.font_key
        next if font[key]?
        entry = ::PDF::Objects::Dictionary.new
        entry["Type"] = ::PDF::Objects::Name.new("Font")
        entry["Subtype"] = ::PDF::Objects::Name.new("Type1")
        entry["BaseFont"] = ::PDF::Objects::Name.new(layer.font_basefont)
        entry["Encoding"] = ::PDF::Objects::Name.new("WinAnsiEncoding")
        font[key] = entry
      end

      if needs_zapf && font[ZapfDingbats::PDF_FONT_KEY]?.nil?
        zapf = ::PDF::Objects::Dictionary.new
        zapf["Type"] = ::PDF::Objects::Name.new("Font")
        zapf["Subtype"] = ::PDF::Objects::Name.new("Type1")
        zapf["BaseFont"] = ::PDF::Objects::Name.new(ZapfDingbats::BASE_FONT)
        # PAS d'Encoding explicite : ZapfDingbats utilise sa propre
        # encoding interne (la table mappe les codepoints 0x21-0xFE
        # sur les ~200 dingbats de la police).
        font[ZapfDingbats::PDF_FONT_KEY] = zapf
      end

      resources["Font"] = font
      page_dict["Resources"] = resources
    end

    # Renvoie un dictionnaire qu'on peut modifier en place sans
    # impacter d'autres pages :
    # * `nil` ou type inattendu → nouveau dict vide
    # * `Dictionary` inline → renvoyé tel quel (déjà local à la page)
    # * `Reference` → résolu, copié superficiellement, retourné
    private def unshare_dict(reader : ::PDF::Reader, obj : ::PDF::Objects::Base?) : ::PDF::Objects::Dictionary
      case obj
      when Nil
        ::PDF::Objects::Dictionary.new
      when ::PDF::Objects::Dictionary
        obj
      when ::PDF::Objects::Reference
        resolved = reader.resolve(obj)
        if dict = resolved.as?(::PDF::Objects::Dictionary)
          copy = ::PDF::Objects::Dictionary.new
          dict.each { |k, v| copy[k] = v }
          copy
        else
          ::PDF::Objects::Dictionary.new
        end
      else
        ::PDF::Objects::Dictionary.new
      end
    end

    # Construit le mapping page index → {n_dans_partition, total_partition}.
    # Les `@toc_pages` premières pages sont nil (= pages TOC, hors
    # logique partition).
    private def build_page_to_partition_map(total : Int32) : Array(Tuple(Int32, Int32)?)
      result = Array(Tuple(Int32, Int32)?).new(total, nil)
      idx = @toc_pages
      @partitions.each do |part_size|
        part_size.times do |i|
          result[idx] = {i + 1, part_size}
          idx += 1
        end
      end
      result
    end

    # Calcule (x, y) en points pour une couche, en tenant compte de
    # la position (cardinale ou duplex-aware) et du sens du livret.
    private def compute_xy(
      layer : Config::Numbering::Layer,
      width : Float64, height : Float64,
      text : String, page_num_pdf : Int32,
    ) : Tuple(Float64, Float64)
      # Résolution outer/inner → left/right selon parité de page
      resolved = resolve_position(layer.position, page_num_pdf)
      v, h = parse_vh(resolved)

      # Largeur réelle du texte (table AFM Helvetica). Indispensable
      # pour aligner correctement à droite : avec l'approximation
      # `0.55 × len`, le texte « - 6 / 12 - » se calculait ~50 % trop
      # large et finissait collé au bord, hors de la pastille.
      text_w = WinAnsi.text_width(text, layer.font_size, layer.bold)

      x = case h
          when "left"   then layer.margin
          when "center" then (width - text_w) / 2
          when "right"  then width - layer.margin - text_w
          else               width - layer.margin - text_w
          end

      y = case v
          when "top"    then height - layer.margin - layer.font_size
          when "bottom" then layer.margin
          else               layer.margin
          end

      {x, y}
    end

    # Résout outer-* / inner-* en position cardinale concrète.
    # Page impaire (recto) : outer = right, inner = left.
    # Page paire (verso)   : outer = left,  inner = right.
    # Si duplex: false → outer ≡ right, inner ≡ left (toujours).
    private def resolve_position(position : String, page_num_pdf : Int32) : String
      return position unless position.starts_with?("outer-") || position.starts_with?("inner-")
      vertical = position.split("-").last # "top" ou "bottom"
      side =
        if @config.duplex
          is_recto = page_num_pdf.odd?
          if position.starts_with?("outer-")
            is_recto ? "right" : "left"
          else
            is_recto ? "left" : "right"
          end
        else
          position.starts_with?("outer-") ? "right" : "left"
        end
      "#{vertical}-#{side}"
    end

    # Décompose "top-right" en {"top", "right"}.
    private def parse_vh(position : String) : Tuple(String, String)
      parts = position.split("-")
      return {parts[0], parts[1]} if parts.size == 2
      {"bottom", "right"}
    end

    private def format(template : String, page : Int32, total : Int32) : String
      template.gsub("%page%", page.to_s).gsub("%total%", total.to_s)
    end

    # Génère le content stream PDF pour toutes les couches d'une page.
    # Style "badge" = dessine un cadre arrondi gris pâle derrière.
    #
    # `cm_inverse` : si fourni, appliquée juste après le `q` initial pour
    # neutraliser une CTM héritée de streams précédents (cas typique :
    # un PDF source ouvre son stream avec `0.75 0 0 -0.75 0 841.92 cm`
    # qui flippe Y et scale ; sans neutralisation, notre overlay sortirait
    # à l'envers et redimensionné).
    private def build_stream(
      layers : Array(Tuple(Float64, Float64, String, Config::Numbering::Layer, String)),
      cm_inverse : Tuple(Float64, Float64, Float64, Float64, Float64, Float64)? = nil,
    ) : String
      String.build do |io|
        io << "q\n"
        if cm_inverse
          a, b, c, d, e, f = cm_inverse
          io << format_cm(a) << ' ' << format_cm(b) << ' '
          io << format_cm(c) << ' ' << format_cm(d) << ' '
          io << format_cm(e) << ' ' << format_cm(f) << " cm\n"
        end
        layers.each do |entry|
          x, y, text, layer, _kind = entry
          render_layer(io, x, y, text, layer)
        end
        io << "Q\n"
      end
    end

    # Formate un nombre PDF (pas de notation scientifique, jusqu'à 6
    # décimales). Trim les zéros trailing pour la propreté.
    private def format_cm(n : Float64) : String
      s = "%.6f" % n
      s = s.rstrip('0')
      s = s.rstrip('.')
      s.empty? || s == "-" ? "0" : s
    end

    # Calcule la CTM cumulée (au niveau de profondeur 0 du graphics
    # state stack) des content streams existants d'une page, puis
    # retourne son inverse. Si la CTM cumulée est l'identité (cas
    # courant des PDF bien formés), retourne `nil` — pas besoin de
    # neutralisation.
    #
    # Algorithme : tokenise chaque stream, suit la profondeur q/Q, et
    # multiplie les `cm` rencontrés à profondeur 0. Les `cm` à
    # profondeur > 0 sont annulés par leur `Q`.
    private def cm_inverse_for_prior_streams(streams : Array(Bytes)) : Tuple(Float64, Float64, Float64, Float64, Float64, Float64)?
      # Identité comme CTM de départ
      a, b, c, d, e, f = 1.0, 0.0, 0.0, 1.0, 0.0, 0.0

      streams.each do |bytes|
        a, b, c, d, e, f = accumulate_cm(String.new(bytes), a, b, c, d, e, f)
      end

      # Si CTM ≈ identité, pas besoin d'inverse
      return if (a - 1.0).abs < 1e-9 && b.abs < 1e-9 &&
                c.abs < 1e-9 && (d - 1.0).abs < 1e-9 &&
                e.abs < 1e-9 && f.abs < 1e-9

      # Inverse de [a b c d e f]
      det = a * d - b * c
      return if det.abs < 1e-12 # non-inversible, on se rabat sur identité

      a_i = d / det
      b_i = -b / det
      c_i = -c / det
      d_i = a / det
      e_i = (c * f - d * e) / det
      f_i = (b * e - a * f) / det
      {a_i, b_i, c_i, d_i, e_i, f_i}
    end

    # Walks `stream` token by token, tracking q/Q depth. When a `cm`
    # is encountered at depth 0, multiplies the current matrix by the
    # 6 numeric arguments preceding it.
    private def accumulate_cm(
      stream : String,
      a : Float64, b : Float64, c : Float64, d : Float64, e : Float64, f : Float64,
    ) : Tuple(Float64, Float64, Float64, Float64, Float64, Float64)
      depth = 0
      pending = [] of Float64

      tokenize_pdf_ops(stream) do |tok|
        case tok
        when "q"
          depth += 1
          pending.clear
        when "Q"
          depth -= 1 if depth > 0
          pending.clear
        when "cm"
          if depth == 0 && pending.size >= 6
            args = pending.last(6)
            a2, b2, c2, d2, e2, f2 = args
            # PDF concat : new_CTM = applied × current_CTM
            # i.e. our (a,b,c,d,e,f) is updated by left-multiplication
            # of (a2,b2,c2,d2,e2,f2). Equivalent matrix form :
            #   [a' b' 0]   [a2 b2 0]   [a b 0]
            #   [c' d' 0] = [c2 d2 0] × [c d 0]
            #   [e' f' 1]   [e2 f2 1]   [e f 1]
            new_a = a2 * a + b2 * c
            new_b = a2 * b + b2 * d
            new_c = c2 * a + d2 * c
            new_d = c2 * b + d2 * d
            new_e = e2 * a + f2 * c + e
            new_f = e2 * b + f2 * d + f
            a, b, c, d, e, f = new_a, new_b, new_c, new_d, new_e, new_f
          end
          pending.clear
        else
          # Numéro : on accumule. Sinon c'est un autre opérateur, on
          # purge la pile d'arguments en attente.
          if numeric_token?(tok)
            pending << tok.to_f64
          else
            pending.clear
          end
        end
      end

      {a, b, c, d, e, f}
    end

    # Tokeniseur PDF minimaliste : split sur whitespace en SAUTANT le
    # contenu des chaînes `(...)` (qui peuvent contenir `q`, `cm`, etc.
    # comme caractères) et des arrays `[...]`. Suffisant pour suivre
    # les opérateurs cm/q/Q et leurs arguments numériques.
    private def tokenize_pdf_ops(stream : String, &) : Nil
      i = 0
      len = stream.bytesize
      tok_start = -1

      while i < len
        ch = stream.byte_at(i)
        case ch
        when '('.ord
          # Saute le contenu de la chaîne PDF (...) en gérant les
          # parenthèses imbriquées et les échappements \( \).
          if tok_start >= 0
            yield stream.byte_slice(tok_start, i - tok_start)
            tok_start = -1
          end
          paren = 1
          i += 1
          while i < len && paren > 0
            c = stream.byte_at(i)
            if c == '\\'.ord
              i += 2
              next
            elsif c == '('.ord
              paren += 1
            elsif c == ')'.ord
              paren -= 1
            end
            i += 1
          end
        when '['.ord
          # Saute jusqu'au ']' correspondant (les arrays peuvent
          # contenir des nombres mais pas d'opérateurs en PDF).
          if tok_start >= 0
            yield stream.byte_slice(tok_start, i - tok_start)
            tok_start = -1
          end
          bracket = 1
          i += 1
          while i < len && bracket > 0
            c = stream.byte_at(i)
            bracket += 1 if c == '['.ord
            bracket -= 1 if c == ']'.ord
            i += 1
          end
        when '<'.ord
          # Saute les chaînes hex <...> et les dictionnaires <<>>
          if tok_start >= 0
            yield stream.byte_slice(tok_start, i - tok_start)
            tok_start = -1
          end
          if i + 1 < len && stream.byte_at(i + 1) == '<'.ord
            angle = 1
            i += 2
            while i < len && angle > 0
              c = stream.byte_at(i)
              if c == '<'.ord && i + 1 < len && stream.byte_at(i + 1) == '<'.ord
                angle += 1
                i += 2
                next
              end
              if c == '>'.ord && i + 1 < len && stream.byte_at(i + 1) == '>'.ord
                angle -= 1
                i += 2
                next
              end
              i += 1
            end
          else
            i += 1
            while i < len && stream.byte_at(i) != '>'.ord
              i += 1
            end
            i += 1
          end
        when '%'.ord
          # Commentaire — saute jusqu'à fin de ligne
          if tok_start >= 0
            yield stream.byte_slice(tok_start, i - tok_start)
            tok_start = -1
          end
          while i < len && stream.byte_at(i) != '\n'.ord && stream.byte_at(i) != '\r'.ord
            i += 1
          end
        when ' '.ord, '\t'.ord, '\n'.ord, '\r'.ord, '\f'.ord
          if tok_start >= 0
            yield stream.byte_slice(tok_start, i - tok_start)
            tok_start = -1
          end
          i += 1
        else
          tok_start = i if tok_start < 0
          i += 1
        end
      end
      if tok_start >= 0
        yield stream.byte_slice(tok_start, len - tok_start)
      end
    end

    private def numeric_token?(tok : String) : Bool
      return false if tok.empty?
      tok.to_f64?.try(&.is_a?(Float64)) || false
    end

    private def render_layer(io : IO, x : Float64, y : Float64, text : String, layer : Config::Numbering::Layer) : Nil
      # Découpe le texte en runs Helvetica vs ZapfDingbats. Permet
      # à l'utilisateur d'écrire des dingbats Unicode (★ ♥ ✦ ✓ ✗ →
      # cf. ZapfDingbats.UNICODE_TO_ZAPF) directement dans son
      # `format:` YAML, sans avoir à embarquer une police TTF.
      runs = ZapfDingbats.split_runs(text)

      # Largeur totale = somme des largeurs de chaque run.
      text_w = runs.sum do |kind, segment|
        case kind
        when :zapf
          segment.size * ZapfDingbats.width(layer.font_size)
        else
          WinAnsi.text_width(segment, layer.font_size, layer.bold)
        end
      end

      # Style avec arrière-plan : on dessine le cadre AVANT le texte.
      if layer.style != "plain"
        # Padding intérieur — généreux pour les ovals/pills, plus
        # serré pour les badges/squares.
        pad_x = case layer.style
                when "oval", "circle" then layer.font_size * 0.9
                else                       layer.font_size * 0.5
                end
        pad_y = layer.font_size * 0.35

        # Centrage vertical du texte dans la pastille :
        # * En PDF, `(text) Tj` dessine à partir de la baseline `y`.
        # * Pour des chiffres/lettres ASCII (pas de descender visible)
        #   le centre visuel du glyphe est à `baseline + cap_height/2`.
        # * Pour Helvetica, cap_height ≈ 0.7 × font_size, donc le
        #   centre visuel du texte est à `y + 0.35 × font_size`.
        # On centre le rectangle sur ce point.
        rh = layer.font_size + 2 * pad_y
        text_visual_center_y = y + layer.font_size * 0.35
        ry = text_visual_center_y - rh / 2
        rx = x - pad_x
        rw = text_w + 2 * pad_x

        # Rayon : la pastille `oval` est totalement arrondie (pill).
        # `circle` est un cercle parfait (carré arrondi à 50%).
        radius = case layer.style
                 when "square" then 0.0
                 when "circle" then [rw, rh].min / 2
                 when "oval"   then rh / 2
                 else               rh / 3 # badge
                 end

        # Bordure et remplissage : un peu plus marqué pour `oval`
        # qui est le style "ça marque l'œil" demandé par défaut.
        case layer.style
        when "oval"
          fill = "0.93 0.93 0.93"
          stroke = "0 0 0"
          stroke_w = 0.6
        when "circle", "square"
          fill = "0.92 0.92 0.92"
          stroke = "0.5 0.5 0.5"
          stroke_w = 0.5
        else # badge
          fill = "0.95 0.95 0.95"
          stroke = "0.75 0.75 0.75"
          stroke_w = 0.4
        end
        draw_rounded_rect(io, rx, ry, rw, rh, radius, fill, stroke, stroke_w)
      end

      r, g, b = layer.color
      io << "BT\n"
      io << format_number(r) << " " << format_number(g) << " " << format_number(b) << " rg\n"
      io << format_number(x) << " " << format_number(y) << " Td\n"

      # Pour chaque run, on switch de font puis on dessine. `Tj`
      # avance automatiquement le curseur de la largeur du glyphe
      # rendu, donc on n'a pas besoin de Td entre les runs.
      runs.each do |kind, segment|
        if kind == :zapf
          io << "/" << ZapfDingbats::PDF_FONT_KEY << " " << format_number(layer.font_size) << " Tf\n"
          # Hex string : <XX YY ZZ> où chaque XX est un byte
          # ZapfDingbats.
          io << '<'
          segment.each_char do |ch|
            cp = ZapfDingbats.codepoint_for(ch)
            io << "%02X" % cp.not_nil! if cp
          end
          io << "> Tj\n"
        else
          io << "/" << layer.font_key << " " << format_number(layer.font_size) << " Tf\n"
          # Le format peut contenir des caractères Unicode (€, †, ‡,
          # …, • – — « » " " etc.) — convertis en bytes WinAnsi
          # avant l'écriture (cf. CombinePDF::WinAnsi).
          io << '('
          WinAnsi.write(io, segment)
          io << ") Tj\n"
        end
      end

      io << "ET\n"
    end

    # Trace un rectangle arrondi (ou un cercle/oval si rayon = min/2).
    # Approximation Bézier classique pour les coins arrondis.
    # `fill` et `stroke` sont des chaînes "R G B" (composantes 0-1).
    private def draw_rounded_rect(io : IO, x : Float64, y : Float64,
                                  w : Float64, h : Float64, r : Float64,
                                  fill : String, stroke : String,
                                  stroke_w : Float64) : Nil
      r = [r, w / 2, h / 2].min
      io << fill << " rg\n"
      io << stroke << " RG\n"
      io << format_number(stroke_w) << " w\n"

      if r <= 0.001
        # Rectangle simple
        io << format_number(x) << " " << format_number(y) << " "
        io << format_number(w) << " " << format_number(h) << " re\n"
      else
        # Path arrondi (4 quadrants Bézier)
        c = r * 0.5523 # constante magique d'approximation circulaire
        x2 = x + w
        y2 = y + h
        # Démarre coin bas-gauche post-arrondi
        io << format_number(x + r) << " " << format_number(y) << " m\n"
        io << format_number(x2 - r) << " " << format_number(y) << " l\n"
        io << format_number(x2 - r + c) << " " << format_number(y) << " "
        io << format_number(x2) << " " << format_number(y + r - c) << " "
        io << format_number(x2) << " " << format_number(y + r) << " c\n"
        io << format_number(x2) << " " << format_number(y2 - r) << " l\n"
        io << format_number(x2) << " " << format_number(y2 - r + c) << " "
        io << format_number(x2 - r + c) << " " << format_number(y2) << " "
        io << format_number(x2 - r) << " " << format_number(y2) << " c\n"
        io << format_number(x + r) << " " << format_number(y2) << " l\n"
        io << format_number(x + r - c) << " " << format_number(y2) << " "
        io << format_number(x) << " " << format_number(y2 - r + c) << " "
        io << format_number(x) << " " << format_number(y2 - r) << " c\n"
        io << format_number(x) << " " << format_number(y + r) << " l\n"
        io << format_number(x) << " " << format_number(y + r - c) << " "
        io << format_number(x + r - c) << " " << format_number(y) << " "
        io << format_number(x + r) << " " << format_number(y) << " c\n"
      end
      io << "B\n" # Fill + Stroke
    end

    private def format_number(n : Float64) : String
      if n == n.to_i64.to_f64
        n.to_i64.to_s
      else
        sprintf("%.4f", n).sub(/0+$/, "").sub(/\.$/, ".0")
      end
    end
  end
end
