# $Id$

# Copyright (C) 2007--2008  American Registry for Internet Numbers ("ARIN")
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND ARIN DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS.  IN NO EVENT SHALL ARIN BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
# OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.

"""HTTPS utilities, both client and server.

At the moment this only knows how to use the PEM certs in my
subversion repository; generalizing it would not be hard, but the more
general version should use SQL anyway.
"""

import httplib, BaseHTTPServer, tlslite.api, glob, traceback, urlparse, socket
import rpki.x509, rpki.exceptions, rpki.log

# This probably should be wrapped somewhere in rpki.x509 eventually
import POW

# Not for production use!
disable_tls_certificate_validation_exceptions = True

rpki_content_type = "application/x-rpki"

class Checker(tlslite.api.Checker):
  """Derived class to handle X.509 client certificate checking."""

  def __init__(self, x509TrustList = None):
    """Initialize our modified certificate checker."""

    self.x509store = POW.X509Store()
    if x509TrustList is not None:
      for x in x509TrustList:
        rpki.log.debug("HTTPS trust anchor %s" % x.getSubject())
        self.x509store.addTrust(x.get_POW())

  def __call__(self, tlsConnection):
    """POW/OpenSSL-based certificate checker."""

    if tlsConnection._client:
      chain = tlsConnection.session.serverCertChain
      peer = "server"
    else:
      chain = tlsConnection.session.clientCertChain
      peer = "client"

    chain = [rpki.x509.X509(tlslite = chain.x509List[i]) for i in range(chain.getNumCerts())]

    for i in range(len(chain)):
      rpki.log.debug("Received cert[%d] %s from %s" % (i, chain[i].getSubject(), peer))

    if not self.x509store.verifyChain(chain[0].get_POW(), [x.get_POW() for x in chain[1:]]):
      if disable_tls_certificate_validation_exceptions:
        rpki.log.warn("DANGER WILL ROBINSON!  IGNORING TLS VALIDATION FAILURE!")
      else:
        raise rpki.exceptions.TLSValidationError

class httpsClient(tlslite.api.HTTPTLSConnection):
  """Derived class to let us replace the default Checker."""

  def __init__(self, host, port = None,
               certChain = None, privateKey = None,
               x509TrustList = None, settings = None):
    """Create a new httpsClient."""

    tlslite.api.HTTPTLSConnection.__init__(
      self, host = host, port = port, settings = settings,
      certChain = certChain, privateKey = privateKey)

    self.checker = Checker(x509TrustList = x509TrustList)

def client(msg, privateKey, certChain, x509TrustList, url, timeout = 300):
  """Open client HTTPS connection, send a message, wait for response.

  This function wraps most of what one needs to do to send a message
  over HTTPS and get a response.  The certificate checking isn't quite
  up to snuff; it's better than with the other packages I've found,
  but doesn't appear to handle subjectAltName extensions (sigh).
  """
  
  u = urlparse.urlparse(url)

  assert u.scheme in ("", "https") and \
         u.username is None and \
         u.password is None and \
         u.params   == "" and \
         u.query    == "" and \
         u.fragment == ""

  # We could add a "settings = foo" argument to the following call to
  # pass in a tlslite.HandshakeSettings object that would let us
  # insist on, eg, particular SSL/TLS versions.

  httpc = httpsClient(host          = u.hostname or "localhost",
                      port          = u.port or 443,
                      privateKey    = privateKey.get_tlslite(),
                      certChain     = certChain.tlslite_certChain(),
                      x509TrustList = x509TrustList)
  httpc.connect()
  httpc.sock.settimeout(timeout)
  httpc.request("POST", u.path, msg, {"Content-Type" : rpki_content_type})
  response = httpc.getresponse()
  if response.status == httplib.OK:
    return response.read()
  else:
    r = response.read()
    raise rpki.exceptions.HTTPRequestFailed, \
          "HTTP request failed with status %s, response %s" % (response.status, r)

class requestHandler(BaseHTTPServer.BaseHTTPRequestHandler):
  """Derived type to supply POST handler and override logging."""

  rpki_handlers = None                  # Subclass must bind

  def rpki_find_handler(self):
    """Helper method to search self.rpki_handlers."""
    for s,h in self.rpki_handlers:
      if self.path.startswith(s):
        return h
    return None

  def do_POST(self):
    """POST handler."""
    try:
      handler = self.rpki_find_handler()
      if self.headers["Content-Type"] != rpki_content_type:
        rcode, rtext = 415, "Received Content-Type %s, expected %s" \
                       % (self.headers["Content-Type"], rpki_content_type)
      elif handler is None:
        rcode, rtext = 404, "No handler found for URL " + self.path
      else:
        rcode, rtext = handler(query = self.rfile.read(int(self.headers["Content-Length"])),
                               path  = self.path)
    except Exception, edata:
      rpki.log.error(traceback.format_exc())
      rcode, rtext = 500, "Unhandled exception %s" % edata
    self.send_response(rcode)
    self.send_header("Content-Type", rpki_content_type)
    self.end_headers()
    self.wfile.write(rtext)

  def log_message(self, format, *args):
    """Redirect HTTP server logging into our own logging system."""
    if args:
      rpki.log.info(format % args)
    else:
      rpki.log.info(format)

class httpsServer(tlslite.api.TLSSocketServerMixIn, BaseHTTPServer.HTTPServer):
  """Derived type to handle TLS aspects of HTTPS."""

  rpki_sessionCache = None
  rpki_privateKey   = None
  rpki_certChain    = None
  rpki_checker      = None
  
  def handshake(self, tlsConnection):
    """TLS handshake handler."""
    assert self.rpki_certChain    is not None
    assert self.rpki_privateKey   is not None
    assert self.rpki_sessionCache is not None
    try:
      #
      # We could add a "settings = foo" argument to the following call
      # to pass in a tlslite.HandshakeSettings object that would let
      # us insist on, eg, particular SSL/TLS versions.
      #
      tlsConnection.handshakeServer(certChain    = self.rpki_certChain,
                                    privateKey   = self.rpki_privateKey,
                                    sessionCache = self.rpki_sessionCache,
                                    checker      = self.rpki_checker,
                                    reqCert      = True)
      tlsConnection.ignoreAbruptClose = True
      return True
    except (tlslite.api.TLSError, rpki.exceptions.TLSValidationError), error:
      rpki.log.warn("TLS handshake failure: " + str(error))
      return False

def server(handlers, privateKey, certChain, port = 4433, host = "", x509TrustList = None):
  """Run an HTTPS server and wait (forever) for connections."""

  if not isinstance(handlers, (tuple, list)):
    handlers = (("/", handlers),)

  class boundRequestHandler(requestHandler):
    rpki_handlers = handlers

  httpd = httpsServer((host, port), boundRequestHandler)

  httpd.rpki_privateKey = privateKey.get_tlslite()
  httpd.rpki_certChain = certChain.tlslite_certChain()
  httpd.rpki_sessionCache = tlslite.api.SessionCache()
  httpd.rpki_checker = Checker(x509TrustList = x509TrustList)

  httpd.serve_forever()
