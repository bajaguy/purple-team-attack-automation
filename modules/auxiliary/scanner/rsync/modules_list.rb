##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary
  include Msf::Exploit::Remote::Tcp
  include Msf::Auxiliary::Scanner
  include Msf::Auxiliary::Report

  RSYNC_HEADER = '@RSYNCD:'

  def initialize
    super(
      'Name'        => 'Rsync Unauthenticated List Command',
      'Description' => 'List all (listable) modules from a rsync daemon',
      'Author'      => 'ikkini',
      'References'  =>
        [
          ['URL', 'http://rsync.samba.org/ftp/rsync/rsync.html']
        ],
      'License'     => MSF_LICENSE
    )
    register_options(
      [
        Opt::RPORT(873)
      ], self.class)
  end

  def read_timeout
    10
  end

  def rsync_requires_auth?(rmodule)
    sock.puts("#{rmodule}\n")
    res = sock.get_once
    if res && (res =~ /^#{RSYNC_HEADER} AUTHREQD/)
      true
    else
      false
    end
  end

  def rsync_list
    sock.puts("#list\n")

    list = []
    # the module listing is the module name and comment separated by a tab, each module
    # on its own line, lines separated with a newline
    sock.get(read_timeout).split(/\n/).map(&:strip).map do |module_line|
      next if module_line =~ /^#{RSYNC_HEADER} EXIT$/
      name, comment = module_line.split(/\t/).map(&:strip)
      list << [ name, comment ]
    end

    list
  end

  def rsync_negotiate
    # rsync is promiscuous and will send the negotitation and motd
    # upon connecting.  abort if we get nothing
    return unless greeting = sock.get_once

    # parse the greeting control and data lines.  With some systems, the data
    # lines at this point will be the motd.
    greeting_control_lines, greeting_data_lines = rsync_parse_lines(greeting)

    # locate the rsync negotiation and complete it by just echo'ing
    # back the same rsync version that it sent us
    version = nil
    greeting_control_lines.map do |greeting_control_line|
      if /^#{RSYNC_HEADER} (?<version>\d+(\.\d+)?)$/ =~ greeting_control_line
        version = Regexp.last_match('version')
        sock.puts("#{RSYNC_HEADER} #{version}\n")
      end
    end

    unless version
      vprint_error("#{ip}:#{rport} - no rsync negotation found")
      return
    end

    _, post_neg_data_lines = rsync_parse_lines(sock.get_once)

    motd_lines = greeting_data_lines + post_neg_data_lines
    [ version, motd_lines.empty? ? nil : motd_lines.join("\n") ]
  end

  # parses the control and data lines from the provided response data
  def rsync_parse_lines(response_data)
    control_lines = []
    data_lines = []

    if response_data
      response_data.strip!
      response_data.split(/\n/).map do |line|
        if line =~ /^#{RSYNC_HEADER}/
          control_lines << line
        else
          data_lines << line
        end
      end
    end

    [ control_lines, data_lines ]
  end

  def run_host(ip)
    connect
    version, motd = rsync_negotiate
    unless version
      vprint_error("#{ip}:#{rport} - does not appear to be rsync")
      disconnect
      return
    end

    info = "rsync protocol version #{version}"
    info += ", MOTD '#{motd}'" if motd
    report_service(
      host: ip,
      port: rport,
      proto: 'tcp',
      name: 'rsync',
      info: info
    )
    vprint_good("#{ip}:#{rport} - rsync MOTD: #{motd}") if motd

    listing = rsync_list
    disconnect
    if listing.empty?
      print_status("#{ip}:#{rport} - rsync #{version}: no modules found")
    else
      print_good("#{ip}:#{rport} - rsync #{version}: #{listing.size} modules found: " \
                 "#{listing.map(&:first).join(', ')}")
      listing.each do |name_comment|
        connect
        rsync_negotiate
        name_comment << rsync_requires_auth?(name_comment.first)
        disconnect
      end

      # build a table to store the module listing in
      listing_table = Msf::Ui::Console::Table.new(
        Msf::Ui::Console::Table::Style::Default,
        'Header' => "rsync modules for #{ip}:#{rport}",
        'Columns' =>
          [
            "Name",
            "Comment",
            "Authentication?"
          ],
        'Rows' => listing
      )
      vprint_line(listing_table.to_s)

      report_note(
        host: ip,
        proto: 'tcp',
        port: rport,
        type: 'rsync_modules',
        data: { modules: listing },
        update: :unique_data
      )
    end
  end
end
