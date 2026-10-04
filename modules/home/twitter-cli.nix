# twitter-cli: reads X (Twitter) from a shell — search, timelines, users,
# single posts — through the web client's GraphQL endpoints, authenticated by
# the session cookies of a browser that is already signed in to x.com. It is
# the X backend Agent-Reach wraps; this declares the CLI itself rather than
# running Agent-Reach's installer, which installs tools imperatively.
#
# Neither package is in nixpkgs. Both are pinned to their PyPI releases.
# Cookies go only to x.com; the one other request, to raw.githubusercontent.com,
# fetches a public list of current GraphQL query IDs (twitter_cli/graphql.py).
{ python3Packages }:
let
  # Builds `X-Client-Transaction-Id` headers. Its 1.0.3 sdist cannot build:
  # setup.py reads a requirements.txt the archive does not contain. The wheel
  # is pure Python, so it is installed instead.
  xclienttransaction = python3Packages.buildPythonPackage rec {
    pname = "xclienttransaction";
    version = "1.0.3";
    format = "wheel";
    src = python3Packages.fetchPypi {
      inherit pname version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-9z3SpLaFb5j6RfDNJsmg/cCyzroOebVSPN+KrH78Wf4=";
    };
    dependencies = [ python3Packages.beautifulsoup4 ];
    pythonImportsCheck = [ "x_client_transaction" ];
  };
in
python3Packages.buildPythonApplication rec {
  pname = "twitter-cli";
  version = "0.8.5";
  pyproject = true;
  src = python3Packages.fetchPypi {
    pname = "twitter_cli";
    inherit version;
    hash = "sha256-gKHwND+bYybYa4wUeo7asQa8R2Zh6d7YBzaObEzV2Wg=";
  };
  # X's logged-out homepage now serves the x-web client, which no longer
  # references the `ondemand.s` bundle the transaction-ID generator parses, so
  # initialisation fails ("'NoneType' object has no attribute 'group'") and
  # SearchTimeline, which requires the header, answers 404. The responsive-web
  # shell at /i/jf/ still carries it. Upstream reports: jackwener/twitter-cli
  # #78 and #88; the same fix merged in Lqm1/x-client-transaction-id#24.
  # Drop this once a release fetches a page that works; the substitution fails
  # the build if the line changes.
  postPatch = ''
    substituteInPlace twitter_cli/client.py \
      --replace-fail '"https://x.com", headers=ct_headers' \
                     '"https://x.com/i/jf/", headers=ct_headers'
  '';
  build-system = [ python3Packages.hatchling ];
  dependencies = with python3Packages; [
    beautifulsoup4
    browser-cookie3
    click
    curl-cffi
    pyyaml
    rich
    xclienttransaction
  ];
  pythonImportsCheck = [ "twitter_cli" ];
  meta.mainProgram = "twitter";
}
