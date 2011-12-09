#!ruby
# coding: utf-8
# -- UTF-8自動判別用コメント :)
require "fileutils"
require "securerandom"
require "tmpdir"
begin
  require "jpeg"
rescue LoadError
end

#
#= EPub作成クラス
#
class EPubMaker
  ZIP = "zip"       # zip command
  UNZIP = "unzip"   # unzip command

  XHTML = "application/xhtml+xml"   # :nodoc:
  CSS = "text/css"                  # :nodoc:

  # OPS core media types
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

  # supported MIME types
  MIME = {
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".txt" => "text/plain",
    ".pdf" => "application/x-pdf",
  }.merge(CORE)

  # finalizer用ディレクトリ削除コールバック生成
  def self.rmdir_callback(dir)
    proc do
      FileUtils.rm_r(dir)
    end
  end

  # 初期化
  def initialize(epub, dir, zip, hash = {})
    hash = hash.dup
    @epub = epub
    @dir = dir
    @zip = zip

    @title = hash.delete(:title)
    @author = hash.delete(:author)
    @width = hash.delete(:width)
    @height = hash.delete(:height)
    @verbose = hash.delete(:verbose){false}
    raise ArgumentError, "unknown paramater: #{hash}" if hash.size > 0
  end

  # 生成実行
  def run
    if @zip
      @dir = unzip_tmpdir(@zip = File.expand_path(@zip))
    else
      @dir = File.expand_path(@dir)
    end
    workdir = make_workdir(@dir)
    files = copy_files(workdir, @dir)
    make_meta(workdir, @dir, files)
    pack_epub(workdir)
  end

  private
  META = "META-INF"     # メタ情報を置く所
  CONTENTS = "OEBPS"    # 実際の中身を置く所

  # zipファイルな元ネタをテンポラリディレクトリに展開
  def unzip_tmpdir(zip)
    dir = File.join(Dir.tmpdir, File.basename(zip, ".zip"))
    Dir.mkdir(dir)
    ObjectSpace.define_finalizer(self, self.class.rmdir_callback(dir))

    system(UNZIP, "-qq", "-o", zip, "-d", dir) || raise
    dir
  end

  # 作業用ディレクトリ作成
  def make_workdir(dir)
    workdir = File.join(Dir.tmpdir, "#{File.basename(__FILE__, '.rb')}-" + File.basename(dir))
    Dir.mkdir(workdir)
    ObjectSpace.define_finalizer(self, self.class.rmdir_callback(workdir))
    workdir
  end

  # 元ネタのうち必要なファイルを作業用ディレクトリにコピー
  def copy_files(workdir, srcdir)
    data_dir = File.join(workdir, CONTENTS, "data")
    FileUtils.mkdir_p(data_dir)

    files = []
    srcs = Dir.glob(File.join(srcdir, "*")).sort
    dots = 0
    srcs.each_with_index do |src, idx|
      unless @verbose
        now = idx * 80 / srcs.size
        if now > dots
          print '.' * (now - dots)
          STDOUT.flush
          dots = now
        end
      end
      dst = "%04d%s" % [idx+1, File.extname(src)]
      print '[%3d/%3d] %s => %s' % [idx + 1, srcs.size, src, dst] if @verbose
      if /\.jpg$/i =~ src && (@width || @height)
        img = nil
        open(src, "rb") do |f|
          img = JPEG.read(f)
        end
        print " (#{img.width} x #{img.height} => " if @verbose

        # grayscaleであればclippingする
        if img.gray?
          clip = img.level(10, 80).clip
          if clip && ((img.width - clip.width) < img.width * 85 / 100 ||
            (img.height - clip.height) < img.height * 85 / 100)
            # 縦か横が15%以上削減できるならたぶんテキスト主体
            img = clip
          else
            # そうでなければたぶんイラスト主体
            #img = img.level(0, 90, true)
          end
        end

        # 必要ならサイズ変換
        width, height = @width, @height
        if img.width > width || img.height > height
          sw = width / img.width.to_f
          sh = height / img.height.to_f
          if sw < sh
            height = (sw * img.height).to_i
          else
            width = (sh * img.width).to_i
          end
        end
        puts "#{width} x #{height})" if @verbose
        img = img.bicubic(width, height)
        img.quality = 80
        open(File.join(data_dir, dst), "wb") do |f|
          JPEG.write(img, f)
        end
      else
        FileUtils.cp(src, File.join(data_dir, dst))
      end
      files.push(dst)
    end
    puts unless @verbose

    files
  end

  # メタ情報等作成
  def make_meta(workdir, srcdir, files)
    if @verbose
      print 'creating meta data...'
      STDOUT.flush
    end

    # mimetype
    open(File.join(workdir, "mimetype"), "w") do |f|
      f.print "application/epub+zip"
    end

    # container.xml
    make_container(File.join(workdir, META))

    # package.opf
    contents_dir = File.join(workdir, CONTENTS)
    bookid = SecureRandom.uuid
    refs = make_opf(contents_dir, bookid, @title, @author, files)

    # ncx
    make_ncx(contents_dir, bookid, @title, refs)

    puts if @verbose
  end

  # container.xml作成
  def make_container(meta_dir)
    Dir.mkdir(meta_dir)
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
  end

  # OPFファイル作成
  def make_opf(contents_dir, bookid, title, author, files)
    data_dir = File.join(contents_dir, "data")
    refs = []

    open(File.join(contents_dir, "package.opf"), "w") do |f|
      f.puts <<-EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookId" xml:lang="ja">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="BookId">#{bookid}</dc:identifier>
    <dc:title>#{h title}</dc:title>
      EOF

      f.puts %'    <dc:creator opf:file-as="#{h author}" opf:role="aut">#{h author}</dc:creator>' if author

      f.puts <<-EOF
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml" />
      EOF

      files.each do |file|
        type = MIME[File.extname(file).downcase]
        next unless type

        # 画像はいきなり表示できるはずだが、ダメなビューアーがはびこってるので
        # XHTML化する
        if CORE[File.extname(file).downcase] && %r"^image/" !~ type
          f.puts %'    <item id="#{File.basename(file, ".*")}" href="data/#{file}" media-type="#{type}" />'
          refs.push(file)
        else
          f.puts %'    <item id="#{File.basename(file, ".*")}" href="data/#{file}" media-type="#{type}" fallback="#{File.basename(fallback = make_fallback(data_dir, file), ".*")}"/>'
          f.puts %'    <item id="#{File.basename(fallback, ".*")}" href="data/#{fallback}" media-type="#{XHTML}" />'
          if %r"^image/" =~ type
            refs.push(fallback)
          else
            refs.push(file)
          end
        end
      end

      f.puts <<-EOF
  </manifest>
  <spine toc="ncx" page-progression-direction="rtl">
      EOF

      refs.each do |file|
        type = MIME[File.extname(file).downcase]
        next if !type || type == CSS
        f.puts %'    <itemref idref="#{file.sub(/\..*$/, "")}" />'
      end

      f.puts <<-EOF
  </spine>
</package>
      EOF
    end

    refs
  end

  # itemのフォールバック用ファイル作成
  def make_fallback(data_dir, file)
    type = MIME[File.extname(file).downcase]
    base = File.basename(file, ".*")
    fallback = base + "-1.xhtml"

    case type
    when %r"^image/"
      open(File.join(data_dir, fallback), "w") do |f|
        f.puts <<-EOF
<?xml version="1.0" encoding="UTF-8"?>
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
<?xml version="1.0" encoding="UTF-8"?>
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
      open(File.join(data_dir, fallback), "w") do |f|
        f.puts <<-EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
  <head>
  <title>#{base}</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  </head>
  <body>
    <a href="data/#{file}">#{file}</a>
  </body>
</html>
        EOF
      end
    end
    fallback
  end

  # NCXファイル作成
  def make_ncx(contents_dir, bookid, title, files)
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

<docTitle><text>#{h title}</text></docTitle>

<navMap>
      EOF

      files.each_with_index do |file, idx|
        label = get_title(File.join(contents_dir, "data", file))
        base = File.basename(file, ".*")
        f.puts %'  <navPoint id="#{base}" playOrder="#{idx+1}">'
        f.puts %'    <navLabel><text>#{h label}</text></navLabel>'
        f.puts %'    <content src="data/#{file}" />'
        f.puts %'  </navPoint>'
      end

      f.puts <<-EOF
</navMap>
</ncx>
      EOF
    end
  end

  # ファイルからタイトルを決定する
  def get_title(fullpath)
    # TODO: 可能なら<title>を抽出
    "Page \##{File.basename(fullpath, ".*").sub(/-\d+$/, "").to_i(10)}"
  end

  # ePubファイル生成
  def pack_epub(workdir)
    print 'creating ePub package...' if @verbose

    File.unlink(@epub) if File.exist?(@epub)
    Dir.chdir(workdir) do
      system(ZIP, "-X", "-r", "-9", "-D", "-q", @epub, "mimetype", META, CONTENTS) || raise
    end

    puts if @verbose
  end

  # HTMLエスケープ
  def h(str)
    str.gsub(/[&\"<>]/, {'&' => '&amp;', '"' => '&qout;', '<' => '&lt;', '>' => '&gt;'})
  end
end


if __FILE__ == $0
  def usage
    puts <<-EOS
#$0 <zipfile | directory> [-o epubfile] [-t title] [-a author] [-s WxH]

-s WxH  SONY Reader: 584x754
        Kindle2: 560x742
        Xperia(FBReader): 480x800
    EOS
    exit 0
  end

  def error(str)
    STDERR.puts str
    STDERR.puts
  end

  zip = nil
  dir = nil
  epub = nil
  title = nil
  author = nil
  width = nil
  height = nil
  verbose = false

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
          epub = ARGV.shift.dup
        end
        epub += ".epub" unless /\.epub$/i =~ epub
      when ?t
        if opt.size > 2
          title = opt[2..-1].lstrip
        elsif ARGV.empty?
          error "-tオプションに書籍名が指定されていません。"
          usage
        else
          title = ARGV.shift.dup
        end
        title.encode!('utf-8')
      when ?a
        if opt.size > 2
          author = opt[2..-1].lstrip
        elsif ARGV.empty?
          error "-aオプションに著者名が指定されていません。"
          usage
        else
          author = ARGV.shift.dup
        end
        author.encode!('utf-8')
      when ?s
        if opt.size > 2
          size = opt[2..-1].lstrip
        elsif ARGV.empty?
          error "-sオプションにサイズが指定されていません。"
          usage
        else
          size = ARGV.shift.dup
        end
        unless /^(\d+)x(\d+)$/ =~ size
          error "-sオプションの指定は 幅x高さ でなければいけません。"
          usage
        end
        unless defined?(JPEG)
          error "-sオプションの指定にはJPEGライブラリが必要です。"
        end
        width = $1.to_i
        height = $2.to_i
      when ?v
        verbose = true
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

  unless title
    title = File.basename(zip || dir, ".*").encode('utf-8')
  end

  maker = EPubMaker.new(epub, dir, zip, title: title, author: author, width: width, height: height, verbose: verbose)
  maker.run
end
