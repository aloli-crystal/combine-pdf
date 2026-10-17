require "option_parser"
require "../combine_pdf"

module CombinePDF
  # Callable CLI entry point. The command logic lives in a method (rather
  # than as top-level code) so it can run both as the standalone
  # `combine-pdf` binary AND in-process from the unified
  # `alolipdf` binary (aloli-crystal/pdf-tools). Returns the exit code.
  module Cli
    # Carries an early-exit code out of OptionParser's *captured* blocks
    # (Crystal forbids `return` there) and out of the helper methods.
    private class Halt < Exception
      getter code : Int32

      def initialize(@code : Int32)
        super()
      end
    end

    # Ouvre `path` dans le viewer PDF par défaut du système, en
    # arrière-plan, **uniquement si STDOUT et STDERR sont des TTY
    # interactifs**. En non-interactif (pipe, cron, CI, redirection
    # vers un fichier), on s'abstient pour ne pas tenter d'ouvrir un
    # PDF dans un contexte sans utilisateur humain.
    #
    # Détection de la commande système :
    # * macOS  → `open` (lance Aperçu ou l'app par défaut, asynchrone)
    # * Linux/BSD → `xdg-open` (paquet xdg-utils — souvent installé)
    #
    # Échec silencieux si aucune commande n'est trouvée OU si le
    # process retourne non-zéro : le PDF est produit, c'est l'essentiel,
    # l'ouverture est un confort.
    private def self.open_in_viewer(path : String) : Nil
      return unless STDOUT.tty? && STDERR.tty?

      opener = {% if flag?(:darwin) %}
                 "open"
               {% else %}
                 "xdg-open"
               {% end %}
      return unless Process.find_executable(opener)

      # On lance en fire-and-forget : `open` (macOS) et `xdg-open`
      # rendent la main immédiatement après avoir délégué au viewer.
      Process.run(opener, [path], output: Process::Redirect::Close, error: Process::Redirect::Close)
    rescue
      # Tout échec d'ouverture est avalé : c'est un confort, pas un
      # contrat. Le PDF est sur disque et le code retour de `build`
      # reste 0.
    end

    def self.run(argv : Array(String)) : Int32
      # `sign` / `verify` are thin forwarders to the ALOLI signing binary
      # (aloli-crystal/pdf-signature). The passphrase is passed through as
      # an env-var NAME, never a value. See `combine_pdf/signer.cr`.
      if (sub = argv[0]?) && (sub == "sign" || sub == "verify")
        return CombinePDF::Signer.forward(sub, argv[1..])
      end

      # combine-pdf CLI.
      #
      # Mode déclaratif (recommandé) :
      #
      #   combine-pdf init [-r]      crée .combine-pdf.yml
      #   combine-pdf refresh [-r]   rafraîchit la liste files:
      #   combine-pdf                construit le livret depuis le YAML
      #   combine-pdf compress F.pdf compresse un PDF unique
      #
      # Sous-commandes historiques :
      #
      #   number    — numérote les pages d'un PDF existant
      #   merge     — concatène plusieurs PDF en un seul
      #   assemble  — merge + numérotation auto (workflow livret en CLI)

      # ─── Drapeaux globaux du mode déclaratif ──────────────────────────
      mode_init = false
      mode_refresh = false
      mode_compress = false
      mode_gs = false
      mode_encrypt = false
      mode_decrypt = false
      mode_rasterize = false
      mode_watermark = false
      recursive = false
      target_dir = "."

      # ─── Drapeaux du mode `watermark` (shell-out interne au module
      #     Watermark du shard aloli-crystal/watermark).
      watermark_text = ""
      watermark_style = "diagonal"
      watermark_opacity = 0.15
      watermark_color = "0.5,0.5,0.5"
      watermark_font_size = 48
      watermark_rotation : Float64? = nil

      # ─── Drapeaux du mode `compress` / `gs` / `encrypt` ───────────────
      compress_in_place = false
      compress_backup = false
      compress_deep = false
      compress_deep_quality : Symbol = :ebook
      compress_linearize = false

      # ─── Drapeaux de chiffrement (mode `encrypt` ET surcharge de build)
      encrypt_user_password : String? = nil
      encrypt_owner_password : String? = nil
      encrypt_level : String? = nil
      encrypt_permissions : String? = nil
      encrypt_force_off = false
      encrypt_force_on = false

      # ─── Drapeau pour ouvrir les PDFs sources chiffrés (mode `build`
      #     ainsi que `decrypt`).
      input_password : String? = nil

      # ─── Drapeau /Rotate flatten — voir `RotationFlattener`. Par
      #     défaut activé : pré-traite via qpdf les PDFs sources dont
      #     une page porte /Rotate ≠ 0 (cas Aperçu macOS).
      flatten_rotation = true

      # ─── Ouverture automatique du PDF produit après un `build` quand
      #     la sortie est un terminal interactif (STDOUT + STDERR sont
      #     des TTY). En non-interactif (cron, CI, redirection), aucune
      #     ouverture pour ne pas surprendre. `--no-open` force off
      #     même en TTY. Ne s'applique qu'à `build`.
      open_after_build = true

      # ─── Paramètres du mode `rasterize` (cf. `Rasterizer`)
      rasterize_dpi = CombinePDF::Rasterizer::DEFAULT_DPI
      rasterize_quality = CombinePDF::Rasterizer::DEFAULT_JPEG_QUALITY
      rasterize_in_place = false

      # ─── Config user (préférences globales pour `init`) ───────────────
      # Chargée AVANT le parsing CLI pour fixer le profil par défaut. Les
      # drapeaux explicites surchargeront ensuite. Précédence (faible →
      # fort) : profil → config user → drapeaux CLI.
      user_config_path = CombinePDF::UserConfig::DEFAULT_PATH
      # Pré-scan minimaliste de --user-config pour permettre de pointer
      # ailleurs (tests, multi-utilisateur).
      argv.each_with_index do |arg, idx|
        case arg
        when "--user-config"
          user_config_path = argv[idx + 1] if idx + 1 < argv.size
        when .starts_with?("--user-config=")
          user_config_path = arg.sub("--user-config=", "")
        end
      end
      user_loaded = CombinePDF::UserConfig.load(user_config_path)

      # ─── Drapeaux du mode `init` (personnalisation du YAML généré) ────
      # Initialisé avec le profil de la config user (booklet par défaut),
      # puis les surcharges de la config sont appliquées. La proc renvoie
      # les options modifiées (struct → semantique de valeur).
      init_options = user_loaded.overrides.call(
        CombinePDF::ConfigInitializer.options_for_profile(user_loaded.profile)
      )
      profile_explicit = false # passé à true dès qu'un --profile est lu

      # ─── Drapeaux des sous-commandes historiques ──────────────────────
      output_path = ""
      partitions : Array(Int32)? = nil
      skip_pages = [] of Int32
      font_size = 10.0
      margin = 24.0
      color_str = "0.2,0.2,0.2"
      global_format = "%page%/%total%"
      partition_format = "%page%/%total%"
      hide_partition_when_single = true

      parser = OptionParser.new do |p|
        p.banner = <<-BANNER
          Usage : combine-pdf SOUS-COMMANDE [options]
                  combine-pdf [options] FICHIERS...

          Mode déclaratif (recommandé pour les livrets) :
            combine-pdf init [options]
              Crée un fichier .combine-pdf.yml dans le dossier
              courant, peuplé avec la liste des PDF présents. Voir les
              options ci-dessous pour personnaliser le YAML généré.

            combine-pdf refresh [-r]
              Met à jour la liste `files:` du YAML : ajoute en fin les
              nouveaux PDF, commente les entrées dont le fichier a
              disparu. Préserve commentaires, ordre et titres existants.

            combine-pdf build
            combine-pdf
              Construit le livret depuis .combine-pdf.yml du
              dossier courant : assemble, numérote, ajoute filigrane,
              page de titre + sommaire cliquable. En terminal interactif,
              le PDF produit est ouvert dans le viewer par défaut
              (Aperçu sur macOS, xdg-open sinon) — passer `--no-open`
              pour désactiver.

            combine-pdf compress FICHIER.pdf [-o SORTIE.pdf | -i] [-L]
              Réduit la taille d'un PDF (recompression Flate uniforme +
              garbage collection des objets orphelins). Gain typique 30-80
              %. Pas de downsampling d'images en pur Crystal — voir le
              flag --deep pour ce besoin (via aloli-crystal/ghostscript).
              Avec `-L / --linearize`, produit un PDF *Fast Web View*
              (ISO 32000-1 § F) pour streaming HTTP — nécessite `qpdf`
              installé.

            combine-pdf gs FICHIER.pdf [-o SORTIE.pdf | -i]
              Normalise un PDF via Ghostscript. Utile quand le parser
              interne refuse un PDF mal formé (ex. PDF linéarisé Acrobat
              ancien avec stream zlib invalide). Court-circuite le parser
              Crystal et délègue tout à gs. Nécessite ghostscript installé.

            combine-pdf encrypt FICHIER.pdf [-o SORTIE.pdf | -i]
                                [-l LEVEL] [-u USER_PWD] [-w OWNER_PWD]
              Chiffre un PDF (Standard Security Handler RC4-128, AES-128
              ou AES-256). Pas besoin du YAML — on opère directement sur
              le fichier passé en argument. Voir aussi la section `encrypt:`
              du YAML pour chiffrer le livret produit par `build`.

            combine-pdf decrypt FICHIER.pdf [-o SORTIE.pdf | -i] [-u PWD]
              Déchiffre un PDF protégé : le sauve sans `/Encrypt` (PDF en
              clair). Le mot de passe (utilisateur OU owner) est fourni
              via `-u` ; vide par défaut pour les PDFs « owner-only
              protected » (cas le plus courant : restrictions sans
              password à l'ouverture). Symétrique de `encrypt`.

            combine-pdf rasterize FICHIER.pdf [-o SORTIE.pdf | -i]
                                [--dpi N] [--quality Q]
              Rastérise chaque page en JPEG plein page (via Ghostscript),
              puis réembarque dans un nouveau PDF. Anti-extraction /
              anti-falsification : plus de texte extractible, un filigrane
              posé avant la rastérisation devient indissociable du contenu.
              Pattern observé chez DossierFacile pour les RIB protégés.
              Compromis : taille fichier en hausse, accessibilité dégradée.
              Nécessite `gs` (Ghostscript) installé.

            combine-pdf watermark FICHIER.pdf -t TEXTE [-o SORTIE.pdf | -i]
                                [-s STYLE] [--opacity O] [--rotation A]
                                [--wm-color R,G,B] [--wm-font-size N]
              Applique un filigrane de texte sur toutes les pages d'un PDF.
              Style : diagonal (défaut), tiled, header, footer, center.
              Pour une protection « indissociable », combiner avec
              `rasterize` en post-traitement :
                  combine-pdf watermark rib.pdf -t "..." -s tiled -i
                  combine-pdf rasterize rib.pdf -i
              Délègue à aloli-crystal/watermark.

          Sous-commandes historiques :
            number FICHIER                Numérote les pages d'un PDF existant
            merge FICHIER1 FICHIER2 ...   Concatène plusieurs PDF
            assemble FICHIER1 FICHIER2 .. Merge + numérotation en une commande

          Signature (délègue au binaire `pdf-sign` de aloli-crystal/pdf-signature) :
            sign -i IN -o OUT -c CERT.p12 -p VAR_ENV [-l b-lt] [-t URL_TSA] ...
                                          Signe un PDF (PAdES B-B/B-T/B-LT/B-LTA).
                                          La phrase de passe est le NOM d'une
                                          variable d'env, jamais sa valeur.
            verify SIGNE.pdf [-a CA.pem]  Vérifie les signatures d'un PDF.
                                          Tous les drapeaux après `sign`/`verify`
                                          sont passés tels quels à `pdfsig`.

          Options :
          BANNER

        # Options communes init / refresh — triées alpha par long flag.
        # NB : l'ordre des `p.on` n'affecte que l'aide affichée. À
        # l'exécution, OptionParser exécute les blocs dans l'ordre
        # des flags sur la ligne de commande.
        p.on("-d DIR", "--dir=DIR", "Dossier cible (défaut : .)") { |v| target_dir = v }
        p.on("-R", "--no-flatten-rotation", "Désactive le pré-traitement `qpdf --flatten-rotation` des PDFs sources dont une page porte /Rotate ≠ 0 (cas Aperçu macOS qui pose un tag de rotation sans réécrire le contenu). Par défaut activé pour `build`/`merge`/`assemble`.") { flatten_rotation = false }
        # Pas de short pour --no-open (les flags de négation sont une
        # exception légitime à la règle « tout long a un short »).
        p.on("--no-open", "Désactive l'ouverture automatique du PDF dans le viewer après un `build`. Par défaut, en terminal interactif, le livret produit est ouvert dans Aperçu (macOS) / le viewer associé (xdg-open Linux/BSD). En non-interactif (cron, CI, redirection), aucune ouverture n'a lieu de toute façon.") { open_after_build = false }
        p.on("-r", "--recursive", "Mode récursif (avec init ou refresh)") { recursive = true }

        p.separator ""
        p.separator "Options pour `init` (personnalisent le YAML généré) — tri alpha :"

        p.on("--author=TEXT", "Override l'auteur (défaut : git config user.name)") { |v| init_options.author = v }
        p.on("--cover=MODE", "Mode couverture : none (défaut) | recto | recto-verso") do |v|
          init_options.cover_mode = v
        end
        p.on("--duplex", "Génère duplex: true (recto-verso)") { init_options.duplex = true }
        p.on("--header", "Active le header de partition (titre du fichier en haut)") do
          init_options.header_state = :enabled
        end
        p.on("--init-format=FMT", "Format global (défaut : '• %page% / %total% •')") do |v|
          init_options.global_format = v
        end
        p.on("--init-output=FILE", "Override le nom du PDF de sortie") { |v| init_options.output = v }
        p.on("--no-numbering", "Désactive toute la numérotation (numbering.enabled: false)") do
          init_options.numbering_enabled = false
        end
        p.on("--paper-size=SIZE", "a4 (défaut) | letter | legal | a3 | a5 | b5 | executive | WxH") do |v|
          init_options.paper_size = v
        end
        p.on("--profile=NAME", "Profil de défauts : booklet (défaut) | book | report | slides | minimal") do |v|
          # Quand --profile est explicite, on ré-applique les surcharges
          # de la config user pour qu'elles l'emportent sur le profil.
          init_options = user_loaded.overrides.call(
            CombinePDF::ConfigInitializer.options_for_profile(v)
          )
          profile_explicit = true
        rescue ex : ArgumentError
          STDERR.puts "Erreur : #{ex.message}"
          raise Halt.new(1)
        end
        p.on("--skip-header", "Omet entièrement la section header du YAML") do
          init_options.header_state = :omitted
        end
        p.on("--skip-toc", "Omet entièrement la section TOC du YAML") { init_options.toc_state = :omitted }
        p.on("--skip-watermark", "Omet entièrement la section filigrane du YAML") do
          init_options.watermark_state = :omitted
        end
        p.on("--title=TEXT", "Override le titre (défaut : nom du dossier)") { |v| init_options.title = v }
        p.on("--toc", "Active la page de titre + sommaire cliquable") { init_options.toc_state = :enabled }
        p.on("--user-config=PATH", "Chemin custom de la config user (défaut : ~/.combine-pdf.yml)") do |_v|
          # Déjà géré par le pré-scan ; ce handler est juste là pour que
          # OptionParser ne se plaigne pas.
        end
        p.on("--watermark=TEXT", "Active la section filigrane avec ce texte") do |v|
          init_options.watermark_state = :enabled
          init_options.watermark_text = v
        end

        p.separator ""
        p.separator "Options pour `compress` — tri alpha :"
        p.on("--backup", "Avec --in-place : conserve l'original sous .bak") { compress_backup = true }
        p.on("--deep", "Compression profonde via gs (downsampling images, JPEG, fonts). Nécessite ghostscript installé.") { compress_deep = true }
        p.on("--deep-quality=Q", "Preset gs : screen | ebook (défaut) | printer | prepress") do |v|
          compress_deep_quality = case v.downcase
                                  when "screen"   then :screen
                                  when "ebook"    then :ebook
                                  when "printer"  then :printer
                                  when "prepress" then :prepress
                                  when "default"  then :default
                                  else
                                    STDERR.puts "Erreur : preset --deep-quality inconnu : #{v}. Attendu : screen | ebook | printer | prepress"
                                    raise Halt.new(1)
                                  end
        end
        p.on("-i", "--in-place", "Réécrit le fichier d'entrée (avec un .tmp atomique)") { compress_in_place = true }
        p.on("-L", "--linearize", "Linéarise le PDF (Fast Web View, ISO 32000-1 § F) — affichage progressif sur HTTP. Nécessite `qpdf` installé. Ne pas combiner avec un PDF déjà signé PAdES.") { compress_linearize = true }

        p.separator ""
        p.separator "Options pour `encrypt` (et surcharges de la section `encrypt:` du YAML lors d'un `build`) — tri alpha :"
        p.on("--encrypt", "Lors d'un `build` : force le chiffrement (avec les options CLI ou défauts AES-256)") do
          encrypt_force_on = true
        end
        p.on("-I PWD", "--input-password=PWD", "Mot de passe à essayer sur les PDFs sources chiffrés (utilisé par `build` et `decrypt`)") do |v|
          input_password = v
        end
        p.on("-l LEVEL", "--level=LEVEL", "Niveau : rc4_128 | aes_128 | aes_256 (défaut : aes_256)") do |v|
          encrypt_level = v
        end
        p.on("--no-encrypt", "Lors d'un `build` : désactive le chiffrement même si présent dans le YAML") do
          encrypt_force_off = true
        end
        p.on("-w PWD", "--owner-password=PWD", "Mot de passe owner (défaut : identique à user)") do |v|
          encrypt_owner_password = v
        end
        p.on("-p LIST", "--permissions=LIST", "Permissions du PDF chiffré (csv : print,copy,modify,annotate). 'none' = tout interdit, 'all' = tout autorisé. Défaut : tout autorisé.") do |v|
          encrypt_permissions = v
        end
        p.on("-u PWD", "--user-password=PWD", "Mot de passe utilisateur (vide = pas de password à l'ouverture)") do |v|
          encrypt_user_password = v
        end

        p.separator ""
        p.separator "Options pour `rasterize` — tri alpha :"
        p.on("--dpi=N", "Résolution de rendu en dpi (défaut : 200). 150 = écran, 300 = imprimable.") do |v|
          rasterize_dpi = v.to_i? || begin
            STDERR.puts "Erreur : --dpi attend un entier (#{v})."
            raise Halt.new(1)
          end
        end
        p.on("-i", "--in-place", "Réécrit le fichier d'entrée (avec un .tmp atomique)") do
          # NB : `-i` est déjà partagé avec `compress` ; ici on positionne
          # un flag dédié pour ne pas marcher sur celui du compresseur.
          rasterize_in_place = true
          compress_in_place = true
        end
        p.on("--quality=Q", "Qualité JPEG 0-100 (défaut : 85)") do |v|
          rasterize_quality = v.to_i? || begin
            STDERR.puts "Erreur : --quality attend un entier (#{v})."
            raise Halt.new(1)
          end
        end

        p.separator ""
        p.separator "Options pour `watermark` — tri alpha :"
        p.on("--opacity=O", "Opacité 0.0-1.0 (défaut : 0.15)") { |v| watermark_opacity = v.to_f }
        p.on("--rotation=A", "Rotation en degrés (défaut : 45 pour diagonal/tiled, 0 ailleurs)") { |v| watermark_rotation = v.to_f }
        p.on("-s STYLE", "--style=STYLE", "Style : diagonal (défaut) | tiled | header | footer | center") { |v| watermark_style = v }
        p.on("-t TEXTE", "--text=TEXTE", "Texte du filigrane (obligatoire pour `watermark`)") { |v| watermark_text = v }
        p.on("--wm-color=R,G,B", "Couleur RGB du filigrane 0.0-1.0 (défaut : 0.5,0.5,0.5)") { |v| watermark_color = v }
        p.on("--wm-font-size=N", "Taille du filigrane (défaut : 48)") { |v| watermark_font_size = v.to_i }

        p.separator ""
        p.separator "Options des sous-commandes historiques — tri alpha :"
        p.on("--color=R,G,B", "Couleur RGB du texte (défaut : 0.2,0.2,0.2)") { |v| color_str = v }
        p.on("--font-size=SIZE", "Taille de police (défaut : 10)") { |v| font_size = v.to_f }
        p.on("--global-format=FMT", "Format global (défaut : '%page%/%total%')") { |v| global_format = v }
        p.on("--margin=PT", "Marge en points (défaut : 24)") { |v| margin = v.to_f }
        p.on("-o FICHIER", "--output=FICHIER", "Fichier de sortie") { |v| output_path = v }
        p.on("--partition-format=FMT", "Format intra-partition") { |v| partition_format = v }
        p.on("--partitions=LIST", "Tailles séparées par virgules (ex: 4,2,1)") do |v|
          partitions = v.split(',').map(&.strip.to_i)
        end
        p.on("--show-single-partitions", "Affiche le numéro intra-partition même pour 1 page") do
          hide_partition_when_single = false
        end
        p.on("--skip=PAGES", "Pages à ne pas numéroter (1-based, virgules)") do |v|
          skip_pages = v.split(',').map(&.strip.to_i)
        end

        p.separator ""
        p.separator "Aide — tri alpha :"
        p.on("-h", "--help", "Affiche l'aide") do
          puts p
          raise Halt.new(0)
        end
        p.on("-v", "--version", "Affiche la version") do
          puts "combine-pdf #{CombinePDF::VERSION}"
          raise Halt.new(0)
        end

        p.invalid_option do |flag|
          STDERR.puts "Option inconnue : #{flag}"
          STDERR.puts p
          raise Halt.new(1)
        end
      end

      positional = [] of String
      parser.unknown_args { |args| positional = args }
      parser.parse(argv)

      # Sous-commandes mode déclaratif : `init`, `refresh`, `build`
      # (équivalentes aux flags `--init`, `--refresh`, ou aucun flag).
      # Permettent une UX plus naturelle :
      #   combine-pdf init       au lieu de combine-pdf --init
      #   combine-pdf refresh    au lieu de combine-pdf --refresh
      #   combine-pdf build      explicitement (vs argument vide)
      if !positional.empty?
        case positional.first
        when "init"
          mode_init = true
          positional = positional[1..]
        when "refresh"
          mode_refresh = true
          positional = positional[1..]
        when "build"
          # Synonyme explicite du mode déclaratif sans argument :
          # on consomme le mot pour que `positional.empty?` plus loin
          # déclenche la branche `build`.
          positional = positional[1..]
        when "compress"
          mode_compress = true
          positional = positional[1..]
        when "gs"
          mode_gs = true
          positional = positional[1..]
        when "encrypt"
          mode_encrypt = true
          positional = positional[1..]
        when "decrypt"
          mode_decrypt = true
          positional = positional[1..]
        when "rasterize"
          mode_rasterize = true
          positional = positional[1..]
        when "watermark"
          mode_watermark = true
          positional = positional[1..]
        when "help", "-h", "--help"
          # `help [sous-commande]` — UX standard. Sans argument c'est
          # l'aide globale (équivalent à --help). Avec argument on filtre
          # le banner sur la sous-commande demandée pour pointer vite à
          # la bonne section.
          sub = positional[1]?
          if sub.nil? || sub.empty?
            puts parser
            return 0
          end
          full = parser.to_s
          # Sections sont séparées par des lignes blanches. On cherche la
          # section qui mentionne la sous-commande dans son titre ou son
          # premier paragraphe et on l'imprime, plus un rappel.
          target = sub.downcase
          # Sous-commandes principales + sous-commandes historiques
          # (merge, assemble, number) + délégations (sign, verify →
          # pdf-sign). Toute entrée listée ici doit avoir une section
          # correspondante dans le banner pour que le filtre `help <sub>`
          # trouve quelque chose à afficher.
          valid_subs = %w[init refresh build compress gs encrypt decrypt rasterize watermark
            merge assemble number sign verify]
          unless valid_subs.includes?(target)
            STDERR.puts "Aide indisponible pour « #{sub} » (sous-commandes : #{valid_subs.join(", ")})."
            STDERR.puts "Utilisez `combine-pdf help` pour l'aide globale."
            return 1
          end
          # Imprimer le banner global puis souligner la sous-commande
          puts full
          puts ""
          puts "─── Focus : #{target} ───"
          full.lines.each_with_index do |line, i|
            if line.includes?("combine-pdf #{target}")
              # Imprimer cette ligne et les ~12 lignes qui la décrivent
              puts ""
              full.lines[i, 12].each { |l| puts l.rstrip }
              break
            end
          end
          return 0
        end
      end

      # ────────────────────────────────────────────────────────────────────
      # Routing : déclaratif d'abord (--init / --refresh / build par défaut),
      # sous-commandes historiques ensuite.
      # ────────────────────────────────────────────────────────────────────

      # Mode --init
      if mode_init
        begin
          target = CombinePDF::ConfigInitializer.init(target_dir, recursive, init_options)
          puts "✓ Créé : #{target}"
          pdfs = CombinePDF::ConfigInitializer.scan_pdfs(target_dir, recursive)
          puts "  #{pdfs.size} fichier(s) PDF listé(s)#{recursive ? " (récursif)" : ""}"
          puts "  Éditez ce fichier puis lancez `combine-pdf` pour construire."
          return 0
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode --refresh
      if mode_refresh
        begin
          summary = CombinePDF::ConfigRefresher.refresh(target_dir, recursive)
          puts "✓ Rafraîchi : #{summary}"
          return 0
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode compress
      if mode_compress
        if positional.empty?
          STDERR.puts "Erreur : compress nécessite un fichier d'entrée."
          STDERR.puts "Usage : combine-pdf compress FICHIER.pdf [-o SORTIE.pdf | -i]"
          return 1
        end
        input = positional.first
        output =
          if compress_in_place
            input
          elsif !output_path.empty?
            output_path
          else
            ext = File.extname(input)
            base = input[0, input.size - ext.size]
            "#{base}-compressed#{ext}"
          end

        begin
          result = CombinePDF::Compressor.compress(
            input, output,
            backup: compress_backup,
            deep: compress_deep,
            deep_quality: compress_deep_quality,
            linearize: compress_linearize,
          )
          annotations = [] of String
          annotations << "deep, gs:#{compress_deep_quality}" if compress_deep
          annotations << "linearized" if compress_linearize
          suffix = annotations.empty? ? "" : " [#{annotations.join(", ")}]"
          puts "✓ #{result}#{suffix}"
          puts "  pages: #{result.pages}"
          if compress_in_place
            puts "  écrit dans : #{input}#{compress_backup ? " (original sauvegardé : #{input}.bak)" : ""}"
          else
            puts "  écrit dans : #{output}"
          end
          return 0
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode gs : normaliser un PDF via Ghostscript (utile quand le pdf
      # shard interne refuse un PDF mal formé / linéarisé ancien).
      # Court-circuite complètement le parser Crystal — on shell-out
      # directement sur gs avec PDFSETTINGS=/default (préserve la
      # qualité, réécrit la structure).
      if mode_gs
        if positional.empty?
          STDERR.puts "Erreur : gs nécessite un fichier d'entrée."
          STDERR.puts "Usage : combine-pdf gs FICHIER.pdf [-o SORTIE.pdf | -i] [--backup]"
          return 1
        end
        unless ::Ghostscript.available?
          STDERR.puts "Erreur : ghostscript (gs) n'est pas installé."
          STDERR.puts "Installation :"
          STDERR.puts "  macOS    : brew install ghostscript"
          STDERR.puts "  FreeBSD  : pkg install ghostscript10"
          STDERR.puts "  Debian   : apt install ghostscript"
          return 1
        end
        input = positional.first
        unless File.exists?(input)
          STDERR.puts "Erreur : fichier introuvable : #{input}"
          return 1
        end
        output =
          if compress_in_place
            "#{input}.tmp.#{Process.pid}"
          elsif !output_path.empty?
            output_path
          else
            ext = File.extname(input)
            base = input[0, input.size - ext.size]
            "#{base}-normalised#{ext}"
          end

        begin
          before = File.size(input).to_i64
          result = ::Ghostscript.compress(input, output, quality: :default)
          unless result.success?
            STDERR.puts "Erreur : gs a échoué (exit #{result.exit_code})"
            stderr_first = result.stderr.lines.first?
            STDERR.puts stderr_first.try(&.strip) if stderr_first
            File.delete(output) if File.exists?(output)
            return 1
          end
          after = File.size(output).to_i64
          if compress_in_place
            FileUtils.cp(input, "#{input}.bak") if compress_backup
            File.rename(output, input)
            final_path = input
          else
            final_path = output
          end
          pct = before == 0 ? 0.0 : (1.0 - after.to_f64 / before) * 100.0
          fmt = ->(b : Int64) {
            kb = b / 1024.0
            kb < 1024 ? "%.1f Ko" % kb : "%.2f Mo" % (kb / 1024.0)
          }
          puts "✓ #{fmt.call(before)} → #{fmt.call(after)} (#{"%.1f" % pct} %) [normalisé via gs]"
          if compress_in_place
            puts "  écrit dans : #{final_path}#{compress_backup ? " (original sauvegardé : #{input}.bak)" : ""}"
          else
            puts "  écrit dans : #{final_path}"
          end
          return 0
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode encrypt : chiffrer un PDF arbitraire (sans passer par le YAML).
      if mode_encrypt
        if positional.empty?
          STDERR.puts "Erreur : encrypt nécessite un fichier d'entrée."
          STDERR.puts "Usage : combine-pdf encrypt FICHIER.pdf [-o SORTIE.pdf | -i]"
          STDERR.puts "                                    [-l LEVEL] [-u USER_PWD] [-w OWNER_PWD]"
          return 1
        end
        input = positional.first
        unless File.exists?(input)
          STDERR.puts "Erreur : fichier introuvable : #{input}"
          return 1
        end

        output =
          if compress_in_place
            "#{input}.tmp.#{Process.pid}"
          elsif !output_path.empty?
            output_path
          else
            ext = File.extname(input)
            base = input[0, input.size - ext.size]
            "#{base}-encrypted#{ext}"
          end

        level_str = (encrypt_level || "aes_256").as(String)
        level_sym = case level_str.downcase
                    when "rc4_128", "rc4-128", "rc4" then :rc4_128
                    when "aes_128", "aes-128"        then :aes_128
                    when "aes_256", "aes-256", "aes" then :aes_256
                    else
                      STDERR.puts "Erreur : niveau de chiffrement inconnu : #{level_str.inspect}"
                      STDERR.puts "Attendu : rc4_128 | aes_128 | aes_256"
                      return 1
                    end

        user_pwd = (encrypt_user_password || "").as(String)
        owner_pwd = (encrypt_owner_password || user_pwd).as(String)
        permissions = parse_permissions_list(encrypt_permissions)

        begin
          pdf = CombinePDF.load(input)
          pdf.encrypt(
            user_password: user_pwd,
            owner_password: owner_pwd,
            level: level_sym,
            permissions: permissions,
          )
          pdf.save(output)

          if compress_in_place
            FileUtils.cp(input, "#{input}.bak") if compress_backup
            File.rename(output, input)
            final_path = input
          else
            final_path = output
          end

          puts "✓ PDF chiffré (#{level_sym})"
          if compress_in_place
            puts "  écrit dans : #{final_path}#{compress_backup ? " (original sauvegardé : #{input}.bak)" : ""}"
          else
            puts "  écrit dans : #{final_path}"
          end
          if user_pwd.empty?
            puts "  ⚠ mot de passe utilisateur VIDE (« owner-only ») — le PDF s'ouvre sans demander de mot de passe."
          end
          return 0
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode decrypt : sauve une version non chiffrée d'un PDF.
      if mode_decrypt
        if positional.empty?
          STDERR.puts "Erreur : decrypt nécessite un fichier d'entrée."
          STDERR.puts "Usage : combine-pdf decrypt FICHIER.pdf [-o SORTIE.pdf | -i] [-u PWD]"
          return 1
        end
        input = positional.first
        unless File.exists?(input)
          STDERR.puts "Erreur : fichier introuvable : #{input}"
          return 1
        end

        output =
          if compress_in_place
            "#{input}.tmp.#{Process.pid}"
          elsif !output_path.empty?
            output_path
          else
            ext = File.extname(input)
            base = input[0, input.size - ext.size]
            "#{base}-decrypted#{ext}"
          end

        # `decrypt` accepte -u (user password) OU -I (input password) ;
        # les deux sont équivalents dans ce contexte (on ouvre un seul
        # fichier chiffré pour le ré-écrire en clair).
        user_pwd = (encrypt_user_password || input_password || "").as(String)

        begin
          pdf = CombinePDF.load(input, password: user_pwd)
          # Pas de pdf.encrypt(...) → la sortie est en clair.
          pdf.save(output)

          if compress_in_place
            FileUtils.cp(input, "#{input}.bak") if compress_backup
            File.rename(output, input)
            final_path = input
          else
            final_path = output
          end

          puts "✓ PDF déchiffré"
          if compress_in_place
            puts "  écrit dans : #{final_path}#{compress_backup ? " (original sauvegardé : #{input}.bak)" : ""}"
          else
            puts "  écrit dans : #{final_path}"
          end
          return 0
        rescue ex : ::PDF::EncryptedPdfError
          STDERR.puts "Erreur : #{ex.message}"
          if user_pwd.empty?
            STDERR.puts ""
            STDERR.puts "Le PDF est chiffré et le mot de passe vide n'a pas suffi."
            STDERR.puts "Fournissez-le via `-u PWD` (ou `--user-password=PWD`)."
            STDERR.puts "Le mot de passe owner fonctionne aussi."
          end
          return 1
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode rasterize : rend chaque page en JPEG plein page (gs)
      # puis réembarque dans un nouveau PDF. Anti-extraction /
      # anti-falsification — voir `CombinePDF::Rasterizer`.
      if mode_rasterize
        if positional.empty?
          STDERR.puts "Erreur : rasterize nécessite un fichier d'entrée."
          STDERR.puts "Usage : combine-pdf rasterize FICHIER.pdf [-o SORTIE.pdf | -i] [--dpi N] [--quality Q]"
          return 1
        end
        input = positional.first
        unless File.exists?(input)
          STDERR.puts "Erreur : fichier introuvable : #{input}"
          return 1
        end

        target_output = if rasterize_in_place
                          input
                        elsif !output_path.empty?
                          output_path
                        else
                          input.sub(/\.pdf$/i, "-rasterized.pdf")
                        end

        begin
          if rasterize_in_place
            tmp = "#{input}.rasterize.tmp.#{Process.pid}.pdf"
            CombinePDF::Rasterizer.rasterize(
              input: input,
              output: tmp,
              dpi: rasterize_dpi,
              jpeg_quality: rasterize_quality,
              password: input_password.to_s,
            )
            File.rename(tmp, input)
          else
            CombinePDF::Rasterizer.rasterize(
              input: input,
              output: target_output,
              dpi: rasterize_dpi,
              jpeg_quality: rasterize_quality,
              password: input_password.to_s,
            )
          end
          before = File.size(input).to_i64
          after = File.size(target_output).to_i64
          puts "PDF rastérisé (#{rasterize_dpi} dpi, qualité #{rasterize_quality}) : #{target_output}"
          puts "Taille : #{(before / 1024.0).round(1)} Ko → #{(after / 1024.0).round(1)} Ko " \
               "(#{((after.to_f / before) * 100).round(1)} %)"
          return 0
        rescue ex : CombinePDF::Rasterizer::Error
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode watermark : applique un filigrane de texte sur toutes les
      # pages d'un PDF. Délègue à `Watermark.apply` du shard
      # aloli-crystal/watermark (déjà dans les dépendances pour l'usage
      # dans `build`, ici exposé en sub-commande standalone).
      if mode_watermark
        if positional.empty?
          STDERR.puts "Erreur : watermark nécessite un fichier d'entrée."
          STDERR.puts "Usage : combine-pdf watermark FICHIER.pdf -t TEXTE [-o SORTIE.pdf | -i] [-s STYLE] [--opacity O] ..."
          return 1
        end
        input = positional.first
        unless File.exists?(input)
          STDERR.puts "Erreur : fichier introuvable : #{input}"
          return 1
        end
        if watermark_text.empty?
          STDERR.puts "Erreur : watermark nécessite un texte (-t TEXTE ou --text=TEXTE)."
          return 1
        end

        target_output = if compress_in_place
                          # Réutilise le flag `-i`/`--in-place` partagé avec compress/rasterize.
                          input
                        elsif !output_path.empty?
                          output_path
                        else
                          input.sub(/\.pdf$/i, "-watermarked.pdf")
                        end

        style_sym = case watermark_style.downcase
                    when "diagonal" then Watermark::Style::Diagonal
                    when "tiled"    then Watermark::Style::Tiled
                    when "header"   then Watermark::Style::Header
                    when "footer"   then Watermark::Style::Footer
                    when "center"   then Watermark::Style::Center
                    else
                      STDERR.puts "Erreur : style inconnu « #{watermark_style} » " \
                                  "(valides : diagonal, tiled, header, footer, center)."
                      return 1
                    end

        color_parts = watermark_color.split(',').map(&.to_f)
        unless color_parts.size == 3
          STDERR.puts "Erreur : --wm-color attend R,G,B (3 flottants 0.0-1.0)."
          return 1
        end
        color_tuple = {color_parts[0], color_parts[1], color_parts[2]}

        default_rotation = (style_sym == Watermark::Style::Diagonal || style_sym == Watermark::Style::Tiled) ? 45.0 : 0.0
        rot = (watermark_rotation || default_rotation).as(Float64)

        wm_options = Watermark::Options.new(
          font_size: watermark_font_size,
          color: color_tuple,
          opacity: watermark_opacity,
          rotation: rot,
          margin: 50,
        )

        begin
          if compress_in_place
            tmp = "#{input}.watermark.tmp.#{Process.pid}.pdf"
            Watermark.apply(input, tmp, watermark_text, style_sym, wm_options)
            File.rename(tmp, input)
          else
            Watermark.apply(input, target_output, watermark_text, style_sym, wm_options)
          end
          puts "Filigrane appliqué (#{watermark_style}) : #{target_output}"
          return 0
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      end

      # Mode déclaratif sans drapeau = build (lit le YAML et produit le PDF)
      if positional.empty?
        yml = File.join(target_dir, CombinePDF::ConfigInitializer::CONFIG_FILENAME)
        if File.exists?(yml)
          begin
            builder = CombinePDF::BookletBuilder.from_dir(target_dir)
            # Surcharges CLI (priorité sur le YAML)
            builder.override_user_password = encrypt_user_password
            builder.override_owner_password = encrypt_owner_password
            builder.override_encrypt_level = encrypt_level
            builder.override_input_password = input_password
            if perms_csv = encrypt_permissions
              builder.override_encrypt_permissions = perms_csv.split(',').map(&.strip).reject(&.empty?)
            end
            if encrypt_force_off
              builder.override_encrypt_enabled = false
            elsif encrypt_force_on
              builder.override_encrypt_enabled = true
            end
            builder.flatten_rotation = flatten_rotation

            output = builder.build
            puts "✓ Livret construit : #{output}"
            open_in_viewer(output) if open_after_build
            return 0
          rescue ex
            STDERR.puts "Erreur : #{ex.message}"
            return 1
          end
        else
          # Pas de YAML. En terminal interactif on propose de le créer
          # maintenant (UX onboarding). En non-interactif (cron, CI,
          # redirection) on garde l'erreur explicite pour ne pas casser
          # les scripts qui s'appuient sur le code retour.
          if STDIN.tty? && STDERR.tty?
            STDERR.puts "Aucun #{CombinePDF::ConfigInitializer::CONFIG_FILENAME} dans #{target_dir}."
            STDERR.print "Voulez-vous le créer maintenant (équivalent de `init`) ? [Y/n] "
            STDERR.flush
            raw = STDIN.gets
            # `nil` = EOF (Ctrl-D ou flux fermé) → on annule explicitement.
            # `""`  = Entrée seule → on accepte (défaut [Y]).
            if raw.nil?
              STDERR.puts ""
              STDERR.puts "Annulé (entrée fermée). Pour le faire plus tard : combine-pdf init"
              return 1
            end
            response = raw.strip.downcase
            if response.empty? || response.in?({"y", "yes", "o", "oui"})
              begin
                target = CombinePDF::ConfigInitializer.init(target_dir, recursive, init_options)
                puts "✓ Créé : #{target}"
                pdfs = CombinePDF::ConfigInitializer.scan_pdfs(target_dir, recursive)
                puts "  #{pdfs.size} fichier(s) PDF listé(s)#{recursive ? " (récursif)" : ""}"
                puts "  Éditez ce fichier puis relancez `combine-pdf` pour construire le livret."
                return 0
              rescue ex
                STDERR.puts "Erreur : #{ex.message}"
                return 1
              end
            else
              STDERR.puts "Annulé. Pour le faire plus tard : combine-pdf init"
              return 1
            end
          else
            STDERR.puts "Erreur : aucune sous-commande spécifiée et aucun #{CombinePDF::ConfigInitializer::CONFIG_FILENAME} trouvé dans #{target_dir}."
            STDERR.puts ""
            STDERR.puts "Pour démarrer : combine-pdf init"
            STDERR.puts parser
            return 1
          end
        end
      end

      subcommand = positional.first
      remaining = positional[1..]

      # ────────────────────────────────────────────────────────────────────
      # Sous-commandes historiques
      # ────────────────────────────────────────────────────────────────────

      case subcommand
      when "number"
        if remaining.empty?
          STDERR.puts "Erreur : `number` attend un fichier PDF en argument"
          STDERR.puts parser
          return 1
        end
        input_path = remaining.first
        unless File.exists?(input_path)
          STDERR.puts "Erreur : fichier introuvable : #{input_path}"
          return 1
        end
        if output_path.empty?
          base = File.basename(input_path, File.extname(input_path))
          dir = File.dirname(input_path)
          output_path = File.join(dir, "#{base}-numbered.pdf")
        end
        options = build_options(font_size, margin, color_str, global_format,
          partition_format, hide_partition_when_single, skip_pages)
        begin
          CombinePDF.number(input: input_path, output: output_path, partitions: partitions, options: options)
          puts "PDF numéroté : #{output_path}"
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      when "merge"
        if remaining.size < 2
          STDERR.puts "Erreur : `merge` attend au moins deux fichiers PDF"
          STDERR.puts parser
          return 1
        end
        remaining.each do |path|
          unless File.exists?(path)
            STDERR.puts "Erreur : fichier introuvable : #{path}"
            return 1
          end
        end
        output_path = "merged.pdf" if output_path.empty?
        begin
          CombinePDF.merge(inputs: remaining, output: output_path, flatten_rotation: flatten_rotation)
          puts "PDF fusionné : #{output_path}"
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      when "assemble"
        if remaining.size < 2
          STDERR.puts "Erreur : `assemble` attend au moins deux fichiers PDF"
          STDERR.puts parser
          return 1
        end
        remaining.each do |path|
          unless File.exists?(path)
            STDERR.puts "Erreur : fichier introuvable : #{path}"
            return 1
          end
        end
        output_path = "livret.pdf" if output_path.empty?
        options = build_options(font_size, margin, color_str, global_format,
          partition_format, hide_partition_when_single, skip_pages)
        begin
          CombinePDF.assemble(inputs: remaining, output: output_path, options: options, flatten_rotation: flatten_rotation)
          puts "Livret assemblé : #{output_path}"
        rescue ex
          STDERR.puts "Erreur : #{ex.message}"
          return 1
        end
      else
        STDERR.puts "Erreur : sous-commande inconnue « #{subcommand} »"
        STDERR.puts parser
        return 1
      end

      0
    rescue ex : Halt
      ex.code
    end

    # Parse une liste CSV de permissions (`print,copy,modify,annotate`),
    # avec les raccourcis `none` (tout interdit) et `all` (tout autorisé,
    # valeur par défaut quand le flag est absent).
    def self.parse_permissions_list(raw : String?) : Array(::PDF::Security::Permission)
      all_perms = [
        ::PDF::Security::Permission::Print,
        ::PDF::Security::Permission::Copy,
        ::PDF::Security::Permission::Modify,
        ::PDF::Security::Permission::Annotate,
      ]
      return all_perms if raw.nil? || raw.strip.empty?
      return [] of ::PDF::Security::Permission if raw.downcase == "none"
      return all_perms if raw.downcase == "all"

      raw.split(',').compact_map do |name|
        case name.strip.downcase
        when "print"    then ::PDF::Security::Permission::Print
        when "copy"     then ::PDF::Security::Permission::Copy
        when "modify"   then ::PDF::Security::Permission::Modify
        when "annotate" then ::PDF::Security::Permission::Annotate
        else
          STDERR.puts "Erreur : permission inconnue : #{name.strip.inspect}"
          STDERR.puts "Attendu (csv) : print, copy, modify, annotate (ou 'none', 'all')."
          raise Halt.new(1)
        end
      end
    end

    def self.build_options(font_size, margin, color_str, global_format, partition_format,
                           hide_partition_when_single, skip_pages) : CombinePDF::Options
      color_parts = color_str.split(',').map(&.to_f)
      if color_parts.size != 3
        STDERR.puts "Erreur : la couleur doit être au format R,G,B (ex : 0.2,0.2,0.2)"
        raise Halt.new(1)
      end
      color = {color_parts[0], color_parts[1], color_parts[2]}

      CombinePDF::Options.new(
        font_size: font_size,
        color: color,
        margin: margin,
        global_format: global_format,
        partition_format: partition_format,
        hide_partition_when_single: hide_partition_when_single,
        skip_pages: skip_pages,
      )
    end
  end
end
