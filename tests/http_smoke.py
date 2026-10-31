"""Real TCP HTTP round trip, with a Python adapter for the LuaSocket API."""
import http.client
import socket
import threading
import time
from urllib.parse import urlencode, urlsplit


def run(lua, plugin_path):
    def bind(host, port):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind((host, int(port)))
        sock.listen(4)
        return sock

    def accept(sock):
        try:
            return sock.accept()[0]
        except BlockingIOError:
            return None

    def receive(sock, size):
        try:
            data = sock.recv(int(size))
        except BlockingIOError:
            return None, "timeout", b""
        if not data:
            return None, "closed", b""
        if len(data) < size:
            return None, "timeout", data
        return data, None, None

    def send(sock, data, offset):
        try:
            count = sock.send(data.encode("utf-8")[int(offset) - 1:])
        except BlockingIOError:
            return None, "timeout", int(offset) - 1
        return int(offset) + count - 1, None, None

    def connect(sock, host, port):
        sock.connect((host, int(port)))
        return True

    globals_ = lua.globals()
    globals_.tcp_bind = bind
    globals_.tcp_accept = accept
    globals_.tcp_receive = receive
    globals_.tcp_send = send
    globals_.udp_socket = lambda: socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    globals_.sock_connect = connect
    globals_.sock_address = lambda sock: sock.getsockname()
    globals_.sock_timeout = lambda sock, timeout: sock.settimeout(timeout)
    globals_.sock_close = lambda sock: sock.close()
    globals_.socket_time = time.time
    globals_.smoke_plugin_path = plugin_path
    lua.execute("""
        package.loaded.socket = nil
        package.loaded.kr_setup = nil
        package.preload.socket = function()
            local wrap
            wrap = function(raw)
                return {
                    settimeout = function(_, t) sock_timeout(raw, t) end,
                    getsockname = function() return sock_address(raw) end,
                    setpeername = function(_, ip, port) return sock_connect(raw, ip, port) end,
                    accept = function() local client = tcp_accept(raw); if client then return wrap(client) end end,
                    receive = function(_, size) return tcp_receive(raw, size) end,
                    send = function(_, data, first) return tcp_send(raw, data, first) end,
                    close = function() sock_close(raw) end,
                }
            end
            return {
                gettime = socket_time,
                udp = function() return wrap(udp_socket()) end,
                bind = function(ip, port) return wrap(tcp_bind(ip, port)) end,
            }
        end
        smoke_saved = false
        smoke_server = assert(require('kr_setup').start{
            path = smoke_plugin_path,
            on_saved = function() smoke_saved = true; smoke_server:stop() end,
        })
    """)
    server = globals_.smoke_server
    url = urlsplit(server.url)

    def round_trip(method, body=None, origin=None):
        result = {}

        def client():
            connection = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
            try:
                headers = {}
                if body is not None:
                    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
                if origin:
                    headers["Origin"] = origin
                connection.request(method, url.path, body=body, headers=headers)
                response = connection.getresponse()
                result.update(status=response.status, body=response.read().decode("utf-8"))
            except Exception as error:
                result["error"] = error
            finally:
                connection.close()

        thread = threading.Thread(target=client)
        thread.start()
        deadline = time.monotonic() + 6
        while thread.is_alive() and time.monotonic() < deadline:
            server.waitEvent(server)
            time.sleep(0.002)
        thread.join(timeout=1)
        assert not thread.is_alive(), "HTTP client hung"
        if "error" in result:
            raise result["error"]
        return result

    try:
        result = round_trip("GET")
        assert result["status"] == 200
        assert "<title>KentRead · 接口配置</title>" in result["body"]
        assert "留空保留原密钥" in result["body"]
        assert "sk-partial" not in result["body"]
        assert 'name="search_api_key"' in result["body"]
        assert "sk-search-only" not in result["body"]
        body = urlencode({
            "base_url": "https://custom.example/v1", "model": "含中文的模型名", "api_key": "sk-tcp-test",
            "search_api_key": "sk-tcp-search",
        })
        result = round_trip("POST", body, "http://" + url.netloc)
        assert result["status"] == 200, result
        assert "配置已保存" in result["body"]
        assert globals_.smoke_saved
        assert server.listener is None
        config = lua.eval("require('kr_config').load")(plugin_path)
        assert config.model == "含中文的模型名"
        assert config.api_key == "sk-tcp-test"
        assert config.search_api_key == "sk-tcp-search"
    finally:
        server.stop(server)
    print("PASS: real TCP GET/POST, UTF-8 form values, and save-triggered shutdown")
