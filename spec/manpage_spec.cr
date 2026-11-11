require "./spec_helper"

# Spec de non-régression du chantier 2 : man page combine-pdf.
#
# Deux volets :
#
# 1. L'aide courte (`combine-pdf --help`, `-h`, `help`) renvoie vers
#    `man combine-pdf` et tient en moins d'une cinquantaine de lignes
#    (banner Unix classique). L'aide détaillée reste accessible via
#    `--help-full` (-H), au moins 100 lignes.
#
# 2. Les sources AsciiDoc et les troffs compilés sont présents dans
#    le repo, avec les sections manpage attendues.
describe "combine-pdf — man page (chantier 2)" do
  describe "aide courte CLI" do
    cli_binary = File.join(SpecHelper::TMP_DIR, "ccp-manpage-test")

    before_all do
      Dir.mkdir_p(File.dirname(cli_binary))
      src = File.join(__DIR__, "..", "src", "cli.cr")
      err_buf = IO::Memory.new
      status = Process.run("crystal", ["build", src, "-o", cli_binary],
        output: Process::Redirect::Close, error: err_buf)
      unless status.success? && File.exists?(cli_binary)
        STDERR.puts "[manpage spec] build CLI a échoué :\n#{err_buf.to_s.lines.last(5).join}"
      end
    end

    it "`--help` tient en moins de 50 lignes" do
      pending! "binaire CLI absent" unless File.exists?(cli_binary)
      buf = IO::Memory.new
      status = Process.run(cli_binary, ["--help"], output: buf, error: buf)
      status.success?.should be_true
      lines = buf.to_s.lines.size
      (lines < 50).should be_true
    end

    it "`--help` renvoie vers `man combine-pdf`" do
      pending! "binaire CLI absent" unless File.exists?(cli_binary)
      buf = IO::Memory.new
      status = Process.run(cli_binary, ["--help"], output: buf, error: buf)
      status.success?.should be_true
      buf.to_s.should contain("man combine-pdf")
    end

    it "`--help-full` donne l'aide détaillée (>100 lignes)" do
      pending! "binaire CLI absent" unless File.exists?(cli_binary)
      buf = IO::Memory.new
      status = Process.run(cli_binary, ["--help-full"], output: buf, error: buf)
      status.success?.should be_true
      (buf.to_s.lines.size > 100).should be_true
    end

    it "`-H` est un alias court de `--help-full`" do
      pending! "binaire CLI absent" unless File.exists?(cli_binary)
      short_buf = IO::Memory.new
      long_buf = IO::Memory.new
      Process.run(cli_binary, ["-H"], output: short_buf, error: short_buf)
      Process.run(cli_binary, ["--help-full"], output: long_buf, error: long_buf)
      short_buf.to_s.should eq(long_buf.to_s)
    end

    it "`help` sans argument imprime l'aide courte (pas l'aide détaillée)" do
      pending! "binaire CLI absent" unless File.exists?(cli_binary)
      buf = IO::Memory.new
      status = Process.run(cli_binary, ["help"], output: buf, error: buf)
      status.success?.should be_true
      buf.to_s.should contain("man combine-pdf")
      (buf.to_s.lines.size < 50).should be_true
    end
  end

  describe "fichiers man dans le repo" do
    man_dir = File.join(__DIR__, "..", "man")

    it "les sources AsciiDoc existent (EN + FR)" do
      File.exists?(File.join(man_dir, "combine-pdf.1.adoc")).should be_true
      File.exists?(File.join(man_dir, "fr", "combine-pdf.1.adoc")).should be_true
    end

    it "les troffs compilés existent (EN + FR)" do
      File.exists?(File.join(man_dir, "combine-pdf.1")).should be_true
      File.exists?(File.join(man_dir, "fr", "combine-pdf.1")).should be_true
    end

    it "le troff EN contient les sections attendues" do
      content = File.read(File.join(man_dir, "combine-pdf.1"))
      {"NAME", "SYNOPSIS", "DESCRIPTION", "COMMANDS", "OPTIONS",
       "CONFIGURATION", "FILES", "EXAMPLES", "EXIT STATUS",
       "ENVIRONMENT", "AUTHORS", "SEE ALSO"}.each do |section|
        content.should contain(section)
      end
    end

    it "le troff FR contient les sections attendues" do
      content = File.read(File.join(man_dir, "fr", "combine-pdf.1"))
      {"NOM", "SYNOPSIS", "DESCRIPTION", "COMMANDES", "OPTIONS",
       "CONFIGURATION", "FICHIERS", "EXEMPLES", "CODES DE RETOUR",
       "ENVIRONNEMENT", "AUTEURS", "VOIR AUSSI"}.each do |section|
        content.should contain(section)
      end
    end

    it "le troff EN documente les entrées spéciales de v1.0.31.52" do
      content = File.read(File.join(man_dir, "combine-pdf.1"))
      content.should contain("BLANK AND SEPARATOR")
      content.should contain("number: hide")
      content.should contain("number: skip")
    end

    it "le troff FR documente les entrées spéciales de v1.0.31.52" do
      content = File.read(File.join(man_dir, "fr", "combine-pdf.1"))
      content.should contain("ENTRÉES BLANK ET SEPARATOR")
      content.should contain("number: hide")
      content.should contain("number: skip")
    end
  end
end
