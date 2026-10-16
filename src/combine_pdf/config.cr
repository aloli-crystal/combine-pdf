module CombinePDF
  # Modèle de données du fichier `.combine-pdf.yml`.
  #
  # Mappé un-pour-un sur la structure du YAML. Pas de `YAML::Serializable`
  # ici — la section `files:` est parsée hors-YAML pour préserver les
  # commentaires et les titres inline lors d'un `--refresh`. Le loader
  # YAML standard est utilisé pour le reste (voir `ConfigLoader`).
  class Config
    # Nom du fichier PDF de sortie.
    property output : String
    # Titre du livret. Écrit dans le `/Info /Title` du PDF.
    property title : String
    # Auteur. Écrit dans le `/Info /Author`.
    property author : String
    # Format de page utilisé pour les pages générées par le shard
    # (TOC, pages blanches, futurs en-têtes/pieds-de-page) :
    # `"a4"`, `"letter"`, `"legal"`, `"a3"`, `"a5"`, ou `"WxH"` en
    # points (ex. `"595x842"`). Défaut `"a4"`.
    #
    # NOTE : ce format n'est PAS imposé aux PDF d'entrée. Un livret
    # peut mélanger A4 + Letter + A3 librement — chaque page garde
    # sa `MediaBox` d'origine. Seules les pages que ce shard
    # GÉNÈRE utilisent `paper_size`.
    property paper_size : String
    # `true` = livret recto-verso. Bascule la sémantique des positions
    # `outer-*` / `inner-*` (alternance par parité).
    property duplex : Bool
    # Configuration des pages de couverture.
    property cover : Cover
    # Configuration de la numérotation des pages.
    property numbering : Numbering
    # Configuration du sommaire (bookmarks + future page texte).
    property toc : Toc?
    # Filigrane optionnel (texte semi-transparent en diagonale, etc.).
    property watermark : Watermark?
    # Chiffrement du livret de sortie (mot de passe + permissions).
    property encrypt : Encrypt?
    # Mot de passe à essayer sur chaque PDF d'ENTRÉE chiffré
    # (« owner-only protected » ou autres). Vide par défaut, ce qui
    # suffit pour ouvrir les PDFs sans password à l'ouverture mais
    # avec restrictions activées (cas le plus courant). Pour des
    # PDFs avec password à l'ouverture, fournir-le ici ou via
    # `combine-pdf --input-password=PWD`.
    property input_password : String
    # Liste ordonnée des fichiers à assembler.
    property files : Array(FileEntry)

    def initialize(
      @output : String = "output.pdf",
      @title : String = "",
      @author : String = "",
      @paper_size : String = "a4",
      @duplex : Bool = false,
      @cover : Cover = Cover.new,
      @numbering : Numbering = Numbering.new,
      @toc : Toc? = nil,
      @watermark : Watermark? = nil,
      @encrypt : Encrypt? = nil,
      @input_password : String = "",
      @files : Array(FileEntry) = [] of FileEntry,
    )
    end

    # Résout le `paper_size` (chaîne) en dimensions `{largeur, hauteur}`
    # exprimées en points PDF (1 pt = 1/72 inch).
    #
    # Accepte les standards `"a4"`, `"letter"`, `"legal"`, `"a3"`,
    # `"a5"` (insensible à la casse) et la forme libre `"WxH"`.
    # Défaut A4 quand la chaîne n'est pas reconnue.
    def self.paper_dimensions(name : String) : Tuple(Float64, Float64)
      case name.downcase
      when "a4"     then {595.0, 842.0}
      when "letter" then {612.0, 792.0}
      when "legal"  then {612.0, 1008.0}
      when "a3"     then {842.0, 1191.0}
      when "a5"     then {420.0, 595.0}
      when "b5"     then {499.0, 709.0}
      when "executive"
        {522.0, 756.0}
      else
        # Forme libre "WxH" en points
        if md = name.match(/^\s*(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)\s*$/i)
          {md[1].to_f, md[2].to_f}
        else
          # Format inconnu → A4 par défaut, silencieusement
          {595.0, 842.0}
        end
      end
    end

    # Une entrée du tableau `files:`.
    #
    # `path` : chemin relatif au dossier du `.combine-pdf.yml`.
    # `title` : libellé personnalisé pour le bookmark / TOC. `nil` = on
    #           dérive du nom de fichier (tirets → espaces, sans
    #           extension).
    # `excluded` : `true` quand l'entrée est en commentaire dans le
    #              YAML (`# - foo.pdf`). Conservée pour que `--refresh`
    #              ne réintroduise pas un fichier que l'utilisateur a
    #              explicitement écarté.
    # `password` : mot de passe spécifique à ce fichier source quand
    #              il est chiffré. `nil` = on retombe sur
    #              `Config#input_password` (global). Permet d'avoir
    #              plusieurs PDFs chiffrés avec des mots de passe
    #              différents dans un même livret.
    record FileEntry,
      path : String,
      title : String? = nil,
      excluded : Bool = false,
      password : String? = nil do
      # Libellé à afficher dans les bookmarks / TOC. Préfère `title`
      # si défini, sinon dérive du nom de fichier.
      def display_title : String
        if t = @title
          t
        else
          base = File.basename(@path, File.extname(@path))
          base.tr("-_", "  ")
        end
      end
    end

    # Couverture avant et arrière.
    #
    # Sémantique :
    # * `mode: "none"`        — pas de couverture
    # * `mode: "recto"`       — 1 page de couverture (avant ET arrière)
    # * `mode: "recto-verso"` — 2 pages de couverture (avant ET arrière)
    #
    # Pour des asymétries (cas rare), surchargez via `front:` / `back:`.
    # Quand `front` ou `back` est non-`nil`, il prime sur `mode`.
    #
    # `include_in_numbering` :
    # * `false` (défaut) — la couverture n'est pas numérotée et la
    #   numérotation démarre à 1 sur la première page de contenu
    # * `true`           — la couverture compte (page 1 = couverture)
    # Ignoré silencieusement quand `mode == "none"`.
    class Cover
      property mode : String
      property front : String?
      property back : String?
      property include_in_numbering : Bool

      def initialize(
        @mode : String = "none",
        @front : String? = nil,
        @back : String? = nil,
        @include_in_numbering : Bool = false,
      )
      end

      # Nombre de pages de couverture en début de livret.
      def front_pages : Int32
        cover_pages_for(@front || @mode)
      end

      # Nombre de pages de couverture en fin de livret.
      def back_pages : Int32
        cover_pages_for(@back || @mode)
      end

      private def cover_pages_for(value : String) : Int32
        case value
        when "none"        then 0
        when "recto"       then 1
        when "recto-verso" then 2
        else                    0
        end
      end
    end

    # Configuration de la numérotation.
    class Numbering
      # Toggle global. `false` = aucune page numérotée.
      property enabled : Bool
      # Couche « numéro global de page » (ex: « 3/12 »).
      property global : Layer
      # Couche « numéro intra-partition » (ex: « 1/4 »).
      property partition : Layer
      # Couche « titre de partition en haut de page » — optionnelle.
      property header : Layer?
      # Liste 1-based de pages à laisser intactes (couvertures
      # additionnelles, intercalaires, etc.).
      property skip_pages : Array(Int32)

      def initialize(
        @enabled : Bool = true,
        @global : Layer = Layer.global_default,
        @partition : Layer = Layer.partition_default,
        @header : Layer? = nil,
        @skip_pages : Array(Int32) = [] of Int32,
      )
      end

      # Une couche de numérotation (global / partition / header).
      #
      # Toutes les couches partagent la même grammaire : activation,
      # format de chaîne (avec `%page%` et `%total%`), style visuel,
      # position, taille de police, couleur, marge.
      class Layer
        property enabled : Bool
        property format : String
        # Style visuel : `"plain"` (texte nu), `"badge"` (cadre arrondi),
        # `"circle"`, `"square"`, `"oval"` (pastille pleine façon
        # tag/pill). Voir `AdvancedNumberer#render_layer` pour le
        # rendu exact.
        property style : String
        # Position cardinale (statique) ou duplex-aware. Liste complète :
        # statiques  : top-left, top-center, top-right,
        #              bottom-left, bottom-center, bottom-right
        # duplex     : outer-top, inner-top, outer-bottom, inner-bottom
        property position : String
        property font_size : Float64
        property color : Tuple(Float64, Float64, Float64)
        property margin : Float64
        # Police grasse (Helvetica-Bold). Cumulable avec `italic`.
        property bold : Bool
        # Police italique (Helvetica-Oblique). Cumulable avec `bold`
        # → Helvetica-BoldOblique.
        property italic : Bool
        # Pour la couche `partition` : ne rien afficher quand la
        # partition fait une seule page. Sans effet pour les autres
        # couches.
        property hide_when_single : Bool

        def initialize(
          @enabled : Bool = true,
          @format : String = "%page%/%total%",
          @style : String = "plain",
          @position : String = "bottom-right",
          @font_size : Float64 = 10.0,
          @color : Tuple(Float64, Float64, Float64) = {0.2, 0.2, 0.2},
          @margin : Float64 = 24.0,
          @bold : Bool = false,
          @italic : Bool = false,
          @hide_when_single : Bool = false,
        )
        end

        # Nom court (`/__CCP_HV__`, `/__CCP_HVB__`, …) à utiliser
        # dans le content stream et à déclarer dans `/Resources /Font`.
        # Mappe (`bold`, `italic`) sur les quatre variants Type1
        # standards de la famille Helvetica.
        def font_key : String
          case {bold, italic}
          when {true, true}  then "__CCP_HVBO__"
          when {true, false} then "__CCP_HVB__"
          when {false, true} then "__CCP_HVO__"
          else                    "__CCP_HV__"
          end
        end

        # Nom PDF de la BaseFont Type1 standard correspondante.
        def font_basefont : String
          case {bold, italic}
          when {true, true}  then "Helvetica-BoldOblique"
          when {true, false} then "Helvetica-Bold"
          when {false, true} then "Helvetica-Oblique"
          else                    "Helvetica"
          end
        end

        # Défauts pour la couche globale (numéro de page du livret).
        # Style "oval" pour avoir une pastille discrète qui marque
        # quand même l'œil (cf. document de référence). Format
        # `• N / T •` qui inclut le total : utile pour savoir où on
        # en est dans le livret quand on tient juste une page. Les
        # puces typographiques WinAnsi (•, U+2022) sont plus
        # élégantes que les tirets ASCII et bien rendues par toutes
        # les Helvetica.
        def self.global_default : Layer
          new(
            format: "\u{2022} %page% / %total% \u{2022}",
            style: "oval",
            position: "bottom-right",
            font_size: 13.0,
            color: {0.2, 0.2, 0.2},
          )
        end

        # Défauts pour la couche partition (marque « 1 / 2 »).
        # Helvetica-Bold 27pt en haut-droite — assez gros pour être
        # vu à 1 mètre par un musicien qui tient sa partition.
        def self.partition_default : Layer
          new(
            format: "%page% / %total%",
            style: "plain",
            position: "top-right",
            font_size: 27.0,
            color: {0.0, 0.0, 0.0},
            bold: true,
            hide_when_single: true,
          )
        end

        # Défauts pour la couche header (titre de partition).
        def self.header_default : Layer
          new(
            position: "top-center",
            font_size: 9.0,
            color: {0.5, 0.5, 0.5},
            margin: 18.0,
          )
        end
      end
    end

    # Configuration du sommaire.
    #
    # `bookmarks` : génère le `/Outlines` du PDF (barre latérale
    # navigable du lecteur).
    #
    # `page` : page texte de titre + sommaire cliquable insérée en
    # tête du livret. Quand activée, elle compte comme une page
    # supplémentaire de couverture (non numérotée par défaut).
    class Toc
      property bookmarks : Bool
      property page : Page?

      def initialize(@bookmarks : Bool = true, @page : Page? = nil)
      end

      # Configuration de la page de titre + sommaire.
      class Page
        property enabled : Bool
        # Titre affiché en gros en haut de page. Vide → utilise
        # `Config#title` ; sinon override.
        property title : String
        # Sous-titre (ex: « Sommaire »). Vide → masqué.
        property subtitle : String
        # Affiche `par <auteur>` quand `Config#author` est non vide.
        property show_author : Bool
        # Affiche les pointillés entre titre et numéro de page.
        property leader_dots : Bool
        # Tailles de police, en points.
        property title_font_size : Float64
        property subtitle_font_size : Float64
        property entry_font_size : Float64
        # Override du format de page utilisé pour la TOC. Vide →
        # hérite de `Config#paper_size`. Mêmes valeurs acceptées
        # (`"a4"`, `"letter"`, `"legal"`, `"a3"`, `"a5"`, `"WxH"`).
        property paper_size : String

        def initialize(
          @enabled : Bool = true,
          @title : String = "",
          @subtitle : String = "Sommaire",
          @show_author : Bool = true,
          @leader_dots : Bool = true,
          @title_font_size : Float64 = 24.0,
          @subtitle_font_size : Float64 = 16.0,
          @entry_font_size : Float64 = 11.0,
          @paper_size : String = "",
        )
        end
      end
    end

    # Filigrane (semi-transparent, en diagonale par défaut).
    #
    # Délégué à `watermark` (`Watermark.apply`). Les
    # styles disponibles correspondent à `Watermark::Style` :
    # `"diagonal"`, `"tiled"`, `"header"`, `"footer"`, `"center"`.
    class Watermark
      property text : String
      property style : String
      property font_size : Int32
      property color : Tuple(Float64, Float64, Float64)
      property opacity : Float64
      property rotation : Float64

      def initialize(
        @text : String,
        @style : String = "diagonal",
        @font_size : Int32 = 48,
        @color : Tuple(Float64, Float64, Float64) = {0.8, 0.8, 0.8},
        @opacity : Float64 = 0.15,
        @rotation : Float64 = 45.0,
      )
      end
    end

    # Chiffrement du livret de sortie. Activé quand la section
    # `encrypt:` est présente dans le YAML, surchargeable par la CLI.
    #
    # Niveau :
    # * `"rc4_128"`  RC4 128-bit (legacy, Acrobat ≥ 5)
    # * `"aes_128"`  AES-128 + CryptFilter AESV2 (Acrobat ≥ 7)
    # * `"aes_256"`  AES-256, PDF 2.0 (Acrobat ≥ X) — défaut
    #
    # Mots de passe :
    # * `user_password` ouvre le PDF (vide = pas de mot de passe à l'ouverture).
    # * `owner_password` lève les restrictions. Vide ou `nil` = égal à
    #   `user_password`.
    # * Les deux peuvent être surchargés en CLI (`--user-password`,
    #   `--owner-password`) — on évite ainsi de stocker un mot de passe
    #   en clair dans le YAML versionné.
    #
    # Permissions : tableau de cases autorisées. `nil` ou absent = tout
    # est permis. Valeurs reconnues : `print`, `copy`, `modify`, `annotate`.
    class Encrypt
      property level : String
      property user_password : String
      property owner_password : String?
      property permissions : Array(String)?
      property encrypt_metadata : Bool

      def initialize(
        @level : String = "aes_256",
        @user_password : String = "",
        @owner_password : String? = nil,
        @permissions : Array(String)? = nil,
        @encrypt_metadata : Bool = true,
      )
      end

      # Convertit la chaîne du YAML en symbol attendu par `pdf.encrypt`.
      def level_symbol : Symbol
        case @level.downcase
        when "rc4_128", "rc4-128", "rc4" then :rc4_128
        when "aes_128", "aes-128"        then :aes_128
        when "aes_256", "aes-256", "aes" then :aes_256
        else
          raise "Niveau de chiffrement inconnu : #{@level.inspect} (attendu : rc4_128, aes_128, aes_256)"
        end
      end

      # Convertit la liste de chaînes (`["print", "copy"]`) en tableau
      # d'enum `PDF::Security::Permission`. Valeur par défaut quand
      # `nil` : toutes les permissions accordées.
      def permissions_for_pdf : Array(::PDF::Security::Permission)
        names = @permissions || ["print", "copy", "modify", "annotate"]
        names.compact_map do |name|
          case name.to_s.downcase
          when "print"    then ::PDF::Security::Permission::Print
          when "copy"     then ::PDF::Security::Permission::Copy
          when "modify"   then ::PDF::Security::Permission::Modify
          when "annotate" then ::PDF::Security::Permission::Annotate
          end
        end
      end
    end
  end
end
