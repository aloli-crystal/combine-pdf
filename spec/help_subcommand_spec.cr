require "./spec_helper"

# Spec d'intégration : la sous-commande `help` doit fonctionner
# (équivalent UX standard de `--help`, et `help <sub>` filtre sur
# une sous-commande). Build le binaire une fois pour tous les tests.
describe "combine-pdf help" do
  cli_binary = File.join(SpecHelper::TMP_DIR, "ccp-help-test")

  before_all do
    # Compilation un seul fois. Le `tmp/` est nettoyé au début de la
    # suite par `spec_helper.cr`, donc on doit construire ici.
    Dir.mkdir_p(File.dirname(cli_binary))
    src = File.join(__DIR__, "..", "src", "cli.cr")
    err_buf = IO::Memory.new
    status = Process.run("crystal", ["build", src, "-o", cli_binary],
      output: Process::Redirect::Close, error: err_buf)
    unless status.success? && File.exists?(cli_binary)
      STDERR.puts "[help spec] build CLI a échoué :\n#{err_buf.to_s.lines.last(5).join}"
    end
  end

  it "`help` sans argument imprime l'usage global" do
    pending! "binaire CLI absent" unless File.exists?(cli_binary)
    buf = IO::Memory.new
    status = Process.run(cli_binary, ["help"], output: buf, error: buf)
    status.success?.should be_true
    s = buf.to_s
    s.should contain("Usage : combine-pdf")
    s.should contain("init")
    s.should contain("refresh")
    s.should contain("encrypt")
  end

  it "`help init` filtre sur la sous-commande init" do
    pending! "binaire CLI absent" unless File.exists?(cli_binary)
    buf = IO::Memory.new
    status = Process.run(cli_binary, ["help", "init"], output: buf, error: buf)
    status.success?.should be_true
    buf.to_s.should contain("Focus : init")
  end

  it "`help <inconnu>` retourne une erreur claire" do
    pending! "binaire CLI absent" unless File.exists?(cli_binary)
    buf = IO::Memory.new
    err_buf = IO::Memory.new
    status = Process.run(cli_binary, ["help", "foobar"], output: buf, error: err_buf)
    status.success?.should be_false
    err_buf.to_s.should contain("Aide indisponible")
    err_buf.to_s.should contain("foobar")
  end

  it "accepte aussi `-h` et `--help` comme alias positionnels" do
    pending! "binaire CLI absent" unless File.exists?(cli_binary)
    %w[-h --help].each do |variant|
      buf = IO::Memory.new
      status = Process.run(cli_binary, [variant], output: buf, error: buf)
      status.success?.should be_true
      buf.to_s.should contain("Usage : combine-pdf")
    end
  end
end
