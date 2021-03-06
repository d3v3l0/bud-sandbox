require 'bfs/bfs_config'

class DataProtocolClient
  # TODO: minimize ruby native code
  # The data protocol is based on the BFS-overlog design.
  # While clients and datanodes are both running BUD instances,
  # they communicate not via BUD tuples but via a custom transfer
  # protocol (below).  Much of this logic can be refactored into BUD.
  
  def DataProtocolClient::chunk_from_fh(fh)
    return fh.read(CHUNKSIZE)
  end

  def DataProtocolClient::send_replicate(chunkid, target, owner)
    args = ["replicate", chunkid, target]
    host, port = owner.split(":")
    puts "send_replicate: #{chunkid}, #{target}, #{owner}"
    begin
      s = TCPSocket.open(host, port)
      s.puts(args.join(","))
      s.close
      return
    rescue
      puts "(connect #{host}:#{port})EXCEPTION ON SEND: #{$!}"
    end 
    ###raise "failed to replicate"
  end

  def DataProtocolClient::read_chunk(chunkid, nodelist)
    fail = 0
    nodelist.each do |node|
      args = ["read", chunkid]
      host, port = node.split(":")
      begin
        s = TCPSocket.open(host, port)
        s.puts(args.join(","))
        ret = s.read(CHUNKSIZE)
        s.close
        return ret
      rescue
        puts "(connect #{host}:#{port}, nodelist #{nodelist}) EXCEPTION ON READ: #{$!}"
        fail += 1
        # go around the loop again.
      end
    end 
    raise "No datanodes.  #{fail} failed attempts"   
  end

  def DataProtocolClient::send_stream(chunkid, prefs, chnk)
    copy = prefs.clone
    first = copy.shift
    host, port = first.split(":")
    copy.unshift(chunkid)
    copy.unshift "pipeline"
    s = TCPSocket.open(host, port)
    s.puts(copy.join(","))
    if chnk.nil?
      s.close
      return false
    else
      s.write(chnk)
      s.close
      return true
    end
  end
end


class DataProtocolServer
  # request types:
  # 1: pipeline.  chunkid, preflist, stream, to_go
  #   - the idea behind to_go is that |preflist| > necessary copies,
  #     but to_go decremements at each successful hop
  # 2: read. chunkid.  send back chnk data from local FS.
  # 3: replicate.  chunkid, preflist. be a client, send local data to another datanode.

  def initialize(port)
    @dir = "#{DATADIR}/#{port}"
    @q = Queue.new
    @q.push false
    Dir.mkdir(DATADIR) unless File.directory? DATADIR
    Dir.mkdir(@dir) unless File.directory? @dir
    start_datanode_server(port)
  end

  def start_datanode_server(port)
    Thread.new do
      @dn_server = TCPServer.open(port)
      loop {
        Thread.start(@dn_server.accept) do |client|
          header = dispatch_dn(client)
          next if conditional_continue
        end
      }
    end
  end
  
  def conditional_continue
    ret = @q.pop
    if ret
      begin
        @dn_server.close
      rescue
        puts "STOP FAILURE #{$!}"
      end
    end
    @q.push false
    return ret
  end

  def dispatch_dn(cli)
    header = cli.gets.chomp
    elems = header.split(",")
    type = elems.shift
    chunkid = elems.shift
    case type
      when "pipeline" 
        do_pipeline(chunkid, elems, cli)
      when "read"
        do_read(chunkid, cli)
      when "replicate"
        do_replicate(chunkid, elems, cli)
    end
  end

  def do_pipeline(chunkid, preflist, cli)
    chunkfile = File.open("#{@dir}/#{chunkid.to_i.to_s}", "w")
    data = cli.read(CHUNKSIZE)
    cli.close
    chunkfile.write data
    chunkfile.close
    
    # synchronous for now...
    if preflist.length > 0
      DataProtocolClient.send_stream(chunkid, preflist, data)
    end
  end
  
  def do_read(chunkid, cli)
    begin
      fp = File.open("#{@dir}/#{chunkid.to_s}", "r")
      chnk = fp.read(CHUNKSIZE)
      fp.close
      cli.write(chnk)
      cli.close
    rescue
      puts "FILE NOT FOUND: *#{chunkid}* (error #{$!})"
      puts "try to ls #{@dir}"
      cli.close
    end
  end

  def do_replicate(chnk, target, cli)
    cli.close
    begin
      fp = File.open("#{@dir}/#{chnk}", "r")
      DataProtocolClient.send_stream(chnk, target, DataProtocolClient.chunk_from_fh(fp))
      fp.close
    rescue
      puts "FAIL: #{$!}"
    end
  end

  def stop_server
    @q.pop
    @q.push true
  end
end
