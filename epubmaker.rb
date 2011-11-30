#!ruby
# coding: utf-8
# -- UTF-8自動判別用コメント :)
require "fileutils"
require "securerandom"
require "tmpdir"

# EPub作成クラス
class EPubMaker
  ZIP = "zip"
  UNZIP = "unzip"

  XHTML = "application/xhtml+xml"
  CSS = "text/css"
  CORE = {
    ".gif" => "image/gif",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".svg" => "image/svg+xml",
    ".htm" => XHTML,
    ".html" => XHTML,
    ".xhtml" => XHTML,
    ".dtb" => "application/x-dtbook+xml",
    ".css" => CSS,
    ".xml" => "application/xml",
  }
  MIME = {
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".txt" => "text/plain",
  }.merge(CORE)

  def self.rmdir_callback(dir)
    proc do
      FileUtils.rm_r(dir)
    end
  end

  def initialize(epub, dir, zip)
    @epub = epub
    @dir = dir
    @zip = zip
  end

  def run
    unzip_tmpdir if @zip
    workdir = make_workdir
    files = copy_files(workdir)
    make_meta(workdir, files)
    pack_epub(workdir)
  end

  private
  CONTENTS = "OEBPS"

  def unzip_tmpdir
    @dir = File.join(Dir.tmpdir, File.basename(@zip, ".zip"))
    Dir.mkdir(@dir)
    ObjectSpace.define_finalizer(self, self.class.rmdir_callback(@dir))

    system(UNZIP, "-qq", "-o", @zip, "-d", @dir) || raise
  end

  def make_workdir
    workdir = File.join(Dir.tmpdir, "#{File.basename(__FILE__, '.rb')}-" + File.basename(@dir))
    Dir.mkdir(workdir)
    ObjectSpace.define_finalizer(self, self.class.rmdir_callback(workdir))
    workdir
  end

  def copy_files(workdir)
    data_dir = File.join(workdir, CONTENTS, "data")
    FileUtils.mkdir_p(data_dir)

    files = []
    Dir.glob(File.join(@dir, "*")).sort.each_with_index do |src, idx|
      dst = "%05d%s" % [idx, File.extname(src)]
      FileUtils.cp(src, File.join(data_dir, dst))
      files.push(dst)
    end
    files
  end

  def make_meta(workdir, files)
    # mimetype
    open(File.join(workdir, "mimetype"), "w") do |f|
      f.print "application/epub+zip"
    end

    meta_dir = File.join(workdir, "META-INF")
    Dir.mkdir(meta_dir)

    # container.xml
    open(File.join(meta_dir, "container.xml"), "w") do |f|
      f.puts <<-EOF
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles>
<rootfile media-type="application/oebps-package+xml" full-path="#{CONTENTS}/package.opf" />
</rootfiles>
</container>
      EOF
    end

    contents_dir = File.join(workdir, CONTENTS)
    data_dir = File.join(contents_dir, "data")

    # package.opf
    bookid = nil
    title = nil
    open(File.join(contents_dir, "package.opf"), "w") do |f|
      f.puts <<-EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookId" xml:lang="ja">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="BookId">#{bookid = SecureRandom.uuid}</dc:identifier>
    <dc:title>#{title = File.basename(@dir)}</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml" />
      EOF

      files.each do |file|
        type = MIME[File.extname(file).downcase]
        next unless type
        if CORE[File.extname(file).downcase]
          f.puts %'    <item id="#{File.basename(file, ".*")}" href="data/#{file}" media-type="#{type}" />'
        else
          f.puts %'    <item id="#{File.basename(file, ".*")}" href="data/#{file}" media-type="#{type}" fallback="#{File.basename(fallback = make_fallback(data_dir, file), ".*")}"/>'
          f.puts %'    <item id="#{fallback.sub(/\..*$/, "")}" href="data/#{fallback}" media-type="#{XHTML}" />'
        end
      end

      f.puts <<-EOF
  </manifest>
  <spine toc="ncx" page-progression-direction="rtl">
      EOF

      files.each do |file|
        type = MIME[File.extname(file).downcase]
        next if !type || type == CSS
        f.puts %'    <itemref idref="#{file.sub(/\..*$/, "")}" />'
      end

      f.puts <<-EOF
  </spine>
</package>
      EOF
    end

    # ncx
    open(File.join(contents_dir, "toc.ncx"), "w") do |f|
      f.puts <<-EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/" xml:lang="ja">
<head>
<meta name="dtb:uid" content="#{bookid}"/>
<meta name="dtb:depth" content="1"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>

<docTitle><text>#{title}</text></docTitle>

<navMap>
      EOF

      files.each_with_index do |file, idx|
        base = File.basename(file, ".*")
        f.puts %'  <navPoint id="#{base}" playOrder="#{idx+1}">'
        f.puts %'    <navLabel><text>#{base}</text></navLabel>'
        f.puts %'    <content src="data/#{file}" />'
        f.puts %'  </navPoint>'
      end

      f.puts <<-EOF
</navMap>
</ncx>
      EOF
    end
  end

  def make_fallback(data_dir, file)
    type = MIME[File.extname(file).downcase]
    base = File.basename(file, ".*")
    fallback = base + "-1.xhtml"

    case type
    when %r"^image/"
      open(File.join(data_dir, fallback), "w") do |f|
        f.puts <<-EOF
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
  <head>
  <title>#{base}</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  </head>
  <body>
    <img src="./#{file}" />
  </body>
</html>
        EOF
      end
    when %r"^text/"
      open(File.join(data_dir, fallback), "w") do |f|
        f.puts <<-EOF
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
  <head>
  <title>#{base}</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  </head>
  <body>
    <pre>
        EOF

        # TODO: encoding
        f.puts File.read(File.join(data_dir, file))

        f.puts <<-EOF
    </pre>
  </body>
</html>
        EOF
      end
    else
      raise "Unsupporte type: #{type} (#{file})"
    end
    fallback
  end

  def pack_epub(workdir)
    File.unlink(@epub) if File.exist?(@epub)
    Dir.chdir(workdir) do
      system(ZIP, "-X", "-r", "-9", "-D", "-q", @epub, "mimetype", "META-INF", CONTENTS) || raise
    end
  end
end


if __FILE__ == $0
  def usage
    puts "#$0 <zipfile | directory> [-o epubfile]"
    exit 0
  end

  def error(str)
    STDERR.puts str
    STDERR.puts
  end

  zip = nil
  dir = nil
  epub = nil

  # コマンドライン処理
  until ARGV.empty?
    opt = ARGV.shift
    if opt[0] == ?-
      case opt[1]
      when ?o
        if opt.size > 2
          epub = opt[2..-1].lstrip
        elsif ARGV.empty?
          error "-oオプションに出力ファイル名が指定されていません。"
          usage
        else
          epub = ARGV.shift
        end
        epub += ".epub" unless /\.epub$/i =~ epub
      when ?h
        usage
      else
        error "不明なオプション %s が指定されました。" % opt
        usage
      end
    elsif zip || dir
      error "入力ファイルが複数指定されています。"
      usage
    else
      if /\.zip$/i =~ opt
        zip = opt
      elsif !File.directory?(opt)
        error "入力ファイル %s がzipファイルまたはディレクトリではありません。" % opt
        usage
      else
        dir = opt
      end
      epub = File.join(Dir.pwd, File.basename(opt, ".zip")) + ".epub" unless epub
    end
  end

  unless zip || dir
    error "入力ファイルが指定されていません。"
    usage
  end

  maker = EPubMaker.new(epub, dir, zip)
  maker.run
end
