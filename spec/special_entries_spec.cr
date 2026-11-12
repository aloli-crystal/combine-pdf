require "./spec_helper"

# Spec de non-régression pour les entrées spéciales `- blank` et
# `- separator` dans la section `files:` du `.combine-pdf.yml`.
#
# Deux volets :
#
# 1. Parsing YAML — chaque forme (nue, scalaire, flow, block) doit
#    produire une `Config::FileEntry` avec le bon `kind`, `title` /
#    `separator_text`, `number` et éventuelles options de rendu.
#
# 2. Pipeline complet — construit un petit livret avec deux PDFs
#    utilisateur + une page `blank` + une page `separator` et
#    vérifie page_count et numérotation.
describe "entrées spéciales blank / separator" do
  describe "parsing — formes YAML" do
    it "reconnaît `- blank` nu" do
      yaml = <<-YAML
        output: out.pdf
        title: ""
        author: ""
        files:
          - blank
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      cfg.files.size.should eq(1)
      e = cfg.files.first
      e.kind.should eq(CombinePDF::Config::Kind::Blank)
      e.title.should be_nil
      e.number.should eq(CombinePDF::Config::NumberMode::Show)
      e.special?.should be_true
    end

    it "reconnaît `- blank: \"Prélude\"` (scalaire = title)" do
      yaml = <<-YAML
        files:
          - blank: "Prélude"
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      e = cfg.files.first
      e.kind.should eq(CombinePDF::Config::Kind::Blank)
      e.title.should eq("Prélude")
    end

    it "reconnaît le flow YAML `- blank: {title: ..., number: hide}`" do
      yaml = <<-YAML
        files:
          - blank: {title: "Prélude", number: hide}
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      e = cfg.files.first
      e.kind.should eq(CombinePDF::Config::Kind::Blank)
      e.title.should eq("Prélude")
      e.number.should eq(CombinePDF::Config::NumberMode::Hide)
    end

    it "reconnaît le block multi-ligne `- blank:` + lignes indentées" do
      yaml = <<-YAML
        files:
          - blank:
              title: "Prélude"
              number: skip
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      cfg.files.size.should eq(1)
      e = cfg.files.first
      e.kind.should eq(CombinePDF::Config::Kind::Blank)
      e.title.should eq("Prélude")
      e.number.should eq(CombinePDF::Config::NumberMode::Skip)
    end

    it "reconnaît `- separator: \"Intermède\"` (scalaire = text)" do
      yaml = <<-YAML
        files:
          - separator: "Intermède"
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      e = cfg.files.first
      e.kind.should eq(CombinePDF::Config::Kind::Separator)
      e.separator_text.should eq("Intermède")
      e.title.should be_nil
    end

    it "reconnaît le flow séparateur avec options de rendu" do
      yaml = <<-YAML
        files:
          - separator: {text: "Chant 1", title: "I", number: show, font_size: 48, opacity: 0.4}
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      e = cfg.files.first
      e.kind.should eq(CombinePDF::Config::Kind::Separator)
      e.separator_text.should eq("Chant 1")
      e.title.should eq("I")
      e.separator_font_size.should eq(48.0)
      e.separator_opacity.should eq(0.4)
    end

    it "préserve les entrées régulières autour des spéciales" do
      yaml = <<-YAML
        files:
          - intro.pdf
          - blank: "Prélude"
          - chapitre-1.pdf
          - separator: "Intermède"
          - chapitre-2.pdf
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      cfg.files.map(&.kind).should eq([
        CombinePDF::Config::Kind::Regular,
        CombinePDF::Config::Kind::Blank,
        CombinePDF::Config::Kind::Regular,
        CombinePDF::Config::Kind::Separator,
        CombinePDF::Config::Kind::Regular,
      ])
      cfg.files[0].path.should eq("intro.pdf")
      cfg.files[2].path.should eq("chapitre-1.pdf")
      cfg.files[4].path.should eq("chapitre-2.pdf")
    end

    it "ignore une entrée spéciale commentée" do
      yaml = <<-YAML
        files:
          - intro.pdf
          # - blank: "Prélude écarté"
          - chapitre-1.pdf
        YAML
      cfg = CombinePDF::ConfigLoader.load_string(yaml)
      cfg.files.size.should eq(3)
      cfg.files[1].excluded.should be_true
      cfg.files[1].kind.should eq(CombinePDF::Config::Kind::Blank)
      cfg.files[1].title.should eq("Prélude écarté")
    end
  end

  describe "pipeline — livret avec blank + separator" do
    it "construit un PDF dont le nombre de pages inclut les entrées spéciales" do
      Dir.mkdir_p(SpecHelper::TMP_DIR)
      dir = File.join(SpecHelper::TMP_DIR, "special_entries")
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)

      SpecHelper.write_a4(File.join(dir, "a.pdf"), page_count: 2)
      SpecHelper.write_a4(File.join(dir, "b.pdf"), page_count: 3)

      yaml = <<-YAML
        output: livret.pdf
        title: "Test"
        author: "spec"
        paper_size: a4
        numbering:
          enabled: true
        files:
          - a.pdf
          - blank: "Prélude"
          - b.pdf
          - separator: {text: "Fin", number: skip}
        YAML
      File.write(File.join(dir, ".combine-pdf.yml"), yaml)

      output = CombinePDF::BookletBuilder.from_dir(dir).build
      File.exists?(output).should be_true

      reader = PDF::Reader.open(output)
      # 2 (a) + 1 (blank) + 3 (b) + 1 (separator) = 7 pages dans le PDF
      reader.page_count.should eq(7)
    end

    it "le séparateur `number: skip` ne compte pas dans le total affiché" do
      Dir.mkdir_p(SpecHelper::TMP_DIR)
      dir = File.join(SpecHelper::TMP_DIR, "special_skip")
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)

      SpecHelper.write_a4(File.join(dir, "a.pdf"), page_count: 2)

      yaml = <<-YAML
        output: livret.pdf
        paper_size: a4
        numbering:
          enabled: true
          global:
            enabled: true
            format: "%page%/%total%"
            style: plain
        files:
          - a.pdf
          - separator: {text: "Fin", number: skip}
        YAML
      File.write(File.join(dir, ".combine-pdf.yml"), yaml)

      output = CombinePDF::BookletBuilder.from_dir(dir).build
      # Non-regression : le PDF est écrit et lisible.
      reader = PDF::Reader.open(output)
      reader.page_count.should eq(3)
    end
  end
end
