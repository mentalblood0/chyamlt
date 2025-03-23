module Chyamlt
  class Server
    def initialize(host : String, port : Int32)
      @handler = HTTP::WebSocketHandler.new do |ws, ctx|
        Log.info { "Connection from #{ctx.request.remote_address}" }
        socket.on_message do |message|
          Log.info { "Message \"#{message}\" from #{ctx.request.remote_address}" }
          socket.send "ok"
        end
      end
      @server = HTTP::Server.new [@handler]
      @address = @server.bind_tcp host, port
      spawn @server.listen
    end
  end

  class Client
    def initialize
    end
  end
end
