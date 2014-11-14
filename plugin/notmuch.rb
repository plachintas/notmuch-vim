require 'notmuch'
require 'rubygems'
require 'tempfile'
require 'socket'
require 'mail'

$db_name = nil
$all_emails = []
$email = $email_name = $email_address = nil
$searches = []
$mail_installed = defined?(Mail)

def get_config_item(item)
    result = ''
    IO.popen(['notmuch', 'config', 'get', item]) { |out|
	result = out.read
    }
    return result.rstrip
end

def get_config
    $db_name = get_config_item('database.path')
    $email_name = get_config_item('user.name')
    $email_address = get_config_item('user.primary_email')
    $secondary_email_addresses = get_config_item('user.primary_email')
    $email_name = get_config_item('user.name')
    $email = "%s <%s>" % [$email_name, $email_address]
    other_emails = get_config_item('user.other_email')
    $all_emails = other_emails.split("\n")
    # Add the primary to this too as we use it for checking
    # addresses when doing a reply
    $all_emails.unshift($email_address)
end

def vim_puts(s)
    VIM::command("echo '#{s.to_s}'")
end

def vim_p(s)
    VIM::command("echo '#{s.inspect}'")
end

def author_filter(a)
    # TODO email format, aliases
    a.strip!
    a.gsub!(/[\.@].*/, '')
    a.gsub!(/^ext /, '')
    a.gsub!(/ \(.*\)/, '')
    a
end

def get_thread_id
    n = $curbuf.line_number - 1
    return "thread:%s" % $curbuf.threads[n]
end

def get_message
    n = $curbuf.line_number
    return $curbuf.messages.find { |m| n >= m.start && n <= m.end }
end

def get_cur_view
    if $cur_filter
	return "#{$curbuf.cur_thread} and (#{$cur_filter})"
    else
	return $curbuf.cur_thread
    end
end

def generate_message_id
    t = Time.now
    random_tag = sprintf('%x%x_%x%x%x',
			 t.to_i, t.tv_usec,
			 $$, Thread.current.object_id.abs, rand(255))
    return "<#{random_tag}@#{Socket.gethostname}.notmuch>"
end

def open_compose_helper(lines, cur)
    help_lines = [
	'Notmuch-Help: Type in your message here; to help you use these bindings:',
	'Notmuch-Help:   ,s    - send the message (Notmuch-Help lines will be removed)',
	'Notmuch-Help:   ,q    - abort the message',
	'Notmuch-Help: Add a filename after the "Attach:" header to attach a file.',
	'Notmuch-Help: Multiple Attach headers may be added.',
    ]

    dir = File.expand_path('~/.notmuch/compose')
    FileUtils.mkdir_p(dir)
    Tempfile.open(['nm-', '.mail'], dir) do |f|
	f.puts(help_lines)
	f.puts
	f.puts(lines)

	sig_file = File.expand_path('~/.signature')
	if File.exists?(sig_file)
	    f.puts("-- ")
	    f.write(File.read(sig_file))
	end

	f.flush

	cur += help_lines.size + 1

	VIM::command("let s:reply_from='%s'" % $email_address)
	VIM::command("call s:new_file_buffer('compose', '#{f.path}')")
	VIM::command("call cursor(#{cur}, 0)")
    end
end

def is_our_address(address)
    $all_emails.each do |addy|
	if address.to_s.index(addy) != nil
	    return addy
	end
    end
    return nil
end

def open_reply(orig)
    reply = orig.reply do |m|
	m.cc = []
	m.to = []
	email_addr = $email_address
	# Use hashes for email addresses so we can eliminate duplicates.
	to = Hash.new
	cc = Hash.new
	if orig[:from]
	    orig[:from].each do |o|
		to[o.address] = o
	    end
	end
	if orig[:cc]
	    orig[:cc].each do |o|
		cc[o.address] = o
	    end
	end
	if orig[:to]
	    orig[:to].each do |o|
		cc[o.address] = o
	    end
	end
	to.each do |e_addr, addr|
	    m.to << addr
	end
	cc.each do |e_addr, addr|
	    if is_our_address(e_addr)
		email_addr = is_our_address(e_addr)
	    else
		m.cc << addr
	    end
	end
	m.to = m[:reply_to] if m[:reply_to]
	m.from = "#{$email_name} <#{email_addr}>"
	m.charset = 'utf-8'
    end

    lines = []

    body_lines = []
    if $mail_installed
	addr = Mail::Address.new(orig[:from].value)
	name = addr.name
	name = addr.local + "@" if name.nil? && !addr.local.nil?
    else
	name = orig[:from]
    end
    name = "somebody" if name.nil?

    body_lines << "%s wrote:" % name
    part = orig.find_first_text
    part.convert.each_line do |l|
	body_lines << "> %s" % l.chomp
    end
    body_lines << ""
    body_lines << ""
    body_lines << ""

    reply.body = body_lines.join("\n")

    lines += reply.present.lines.map { |e| e.chomp }
    lines << ""

    cur = lines.count - 1

    open_compose_helper(lines, cur)
end

def open_compose(to_email)
    lines = []

    lines << "From: #{$email}"
    lines << "To: #{to_email}"
    cur = lines.count

    lines << "Cc: "
    lines << "Bcc: "
    lines << "Subject: "
    lines << "Attach: "
    lines << ""
    lines << ""

    open_compose_helper(lines, cur)
end

def folders_render()
    $curbuf.render do |b|
	folders = VIM::evaluate('g:notmuch_folders')
	count_threads = VIM::evaluate('g:notmuch_folders_count_threads') == 1
	$searches.clear
	longest_name = 0
	folders.each do |name, search|
	    if name.length > longest_name
		longest_name = name.length
	    end
	end
	folders.each do |name, search|
	    q = $curbuf.query(search)
	    $searches << search
	    count = count_threads ? q.search_threads.count : q.search_messages.count
	    if name == ''
		b << ""
	    else
		b << "%9d %-#{longest_name + 1}s (%s)" % [count, name, search]
	    end
	end
    end
end

def search_render(search)
    date_fmt = VIM::evaluate('g:notmuch_date_format')
    q = $curbuf.query(search)
    q.sort = Notmuch::SORT_NEWEST_FIRST
    $curbuf.threads.clear
    t = q.search_threads

    $render = $curbuf.render_staged(t) do |b, items|
	items.each do |e|
	    authors = e.authors.to_utf8.split(/[,|]/).map { |a| author_filter(a) }.join(",")
	    date = Time.at(e.newest_date).strftime(date_fmt)
	    subject = e.messages.first['subject']
	    if $mail_installed
		subject = Mail::Field.new("Subject: " + subject).to_s
	    else
		subject = subject.force_encoding('utf-8')
	    end
	    b << "%-12s %3s %-20.20s | %s (%s)" % [date, e.matched_messages, authors, subject, e.tags]
	    $curbuf.threads << e.thread_id
	end
    end
end

def do_tag(filter, tags)
    $curbuf.do_write do |db|
	q = db.query(filter)
	q.search_messages.each do |e|
	    e.freeze
	    tags.split.each do |t|
		case t
		when /^-(.*)/
		    e.remove_tag($1)
		when /^\+(.*)/
		    e.add_tag($1)
		when /^([^\+^-].*)/
		    e.add_tag($1)
		end
	    end
	    e.thaw
	    e.tags_to_maildir_flags
	end
	q.destroy!
    end
end

module DbHelper
    def init_dbhelper
	@db = Notmuch::Database.new($db_name)
	@queries = []
    end

    def query(*args)
	q = @db.query(*args)
	@queries << q
	q
    end

    def message(id)
	@db.find_message(id)
    end

    def close
	@queries.delete_if { |q| ! q.destroy! }
	@db.close
    end

    def reopen
	close if @db
	@db = Notmuch::Database.new($db_name)
    end

    def do_write
	db = Notmuch::Database.new($db_name, :mode => Notmuch::MODE_READ_WRITE)
	begin
	    yield db
	ensure
	    db.close
	end
    end
end

module URI
    class MsgID < Generic
    end

    @@schemes['ID'] = MsgID
end

class Message
    attr_accessor :start, :body_start, :end, :full_header_start, :full_header_end
    attr_reader :message_id, :filename, :mail, :tags

    def initialize(msg, mail)
	@message_id = msg.message_id
	@filename = msg.filename
	@mail = mail
	@start = 0
	@end = 0
	@full_header_start = 0
	@full_header_end = 0
	@tags = msg.tags
	mail.import_headers(msg) if not $mail_installed
    end

    def to_s
	"id:%s" % @message_id
    end

    def inspect
	"id:%s, file:%s" % [@message_id, @filename]
    end
end

class StagedRender
    def initialize(buffer, enumerable, block)
	@b = buffer
	@enumerable = enumerable
	@block = block
	@last_render = 0

	@b.render { do_next }

	@last_render = @b.count
    end

    def is_ready?
	@last_render - @b.line_number <= $curwin.height
    end

    def do_next
	items = @enumerable.take($curwin.height * 2)
	return if items.empty?
	@block.call @b, items
	@last_render = @b.count
    end
end

class VIM::Buffer
    include DbHelper
    attr_accessor :messages, :threads, :cur_thread


    def init(name)
	@name = name
	@messages = []
	@threads = []

	init_dbhelper()
    end

    def <<(a)
	append(count(), a)
    end

    def render_staged(enumerable, &block)
	StagedRender.new(self, enumerable, block)
    end

    def render
	old_count = count
	yield self
	(1..old_count).each do
	    delete(1)
	end
    end
end

class Notmuch::Tags
    def to_s
	to_a.join(" ")
    end
end

class Notmuch::Message
    def to_s
	"id:%s" % message_id
    end
end

# workaround for bug in vim's ruby
class Object
    def flush
    end
end

module Mail

    class Message

	def find_first_text
	    return self if not multipart?
	    return text_part || html_part
	end

	def convert
	    if mime_type != "text/html"
		text = decoded
	    else
		IO.popen(VIM::evaluate('exists("g:notmuch_html_converter") ? ' +
				       'g:notmuch_html_converter : "elinks --dump"'), "w+") do |pipe|
		    pipe.write(decode_body)
		    pipe.close_write
		    text = pipe.read
		end
	    end
	    text
	end

	def present
	    buffer = ''
	    header.fields.each do |f|
		buffer << "%s: %s\r\n" % [f.name, f.to_s]
	    end
	    buffer << "Attach: \r\n"
	    buffer << "\r\n"
	    buffer << body.to_s
	    buffer
	end
    end
end

class String
    def to_utf8
	RUBY_VERSION >= "1.9" ? force_encoding('utf-8') : self
    end
end

get_config
