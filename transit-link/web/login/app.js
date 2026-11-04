/* One sign-in form for everyone. What you type decides where you land:
     a phone number + PIN        -> rider app
     a username + password       -> operator dashboard
     a device ID (no passcode)   -> validator
   The screen never says which kind of account exists, and failures use one generic message. */
mountIcons();

var existing = Session.get();
if (existing) go(Session.home(existing.role));

var mode = new URLSearchParams(location.search).get('mode') === 'signup' ? 'signup' : 'signin';
var PHONE_LIKE = /^\+?[\d\s-]{9,15}$/;
var GENERIC = "We couldn't find an account with those details. Check them and try again.";

function render() {
  var up = mode === 'signup';
  document.title = (up ? 'Create account' : 'Sign in') + ' · Transit Link';
  $('title').textContent = up ? 'Create your account' : 'Welcome back';
  $('intro').textContent = up ? 'Use your M-Pesa number to get started.' : 'Sign in to continue.';
  show($('f-name'), up);
  $('ident-label').textContent = up ? 'Phone number' : 'Account';
  $('ident').placeholder = up ? '07XX XXX XXX' : 'Phone number or ID';
  $('ident').setAttribute('inputmode', up ? 'tel' : 'text');
  $('secret-label').textContent = up ? 'Choose a PIN (4 to 8 digits)' : 'Passcode';
  $('secret').placeholder = up ? 'Digits only' : 'Enter your passcode';
  $('secret').autocomplete = up ? 'new-password' : 'current-password';
  $('submit').textContent = up ? 'Create account' : 'Sign in';
  $('switch-text').textContent = up ? 'Already have an account?' : 'New here?';
  $('switch').textContent = up ? 'Sign in' : 'Create an account';
  $('switch').href = up ? '?mode=signin' : '?mode=signup';
  say($('msg'), '');
}

$('switch').onclick = function (e) {
  e.preventDefault();
  mode = mode === 'signup' ? 'signin' : 'signup';
  history.replaceState(null, '', '?mode=' + mode);
  render();
};

$('reveal').onclick = function () {
  var input = $('secret');
  var hidden = input.type === 'password';
  input.type = hidden ? 'text' : 'password';
  $('reveal').setAttribute('aria-label', hidden ? 'Hide passcode' : 'Show passcode');
};

async function signIn(ident, secret) {
  if (PHONE_LIKE.test(ident)) {
    if (!secret) throw new Error('Enter your passcode.');
    var r = await api('/auth/login', { method: 'POST', body: { phone: ident, pin: secret } });
    return { role: 'rider', token: r.token, name: r.name };
  }
  if (secret) {
    try {
      var o = await api('/auth/operator/login', { method: 'POST', body: { username: ident, password: secret } });
      return { role: 'operator', token: o.token, name: o.name };
    } catch (e) { if (e.status !== 401) throw e; }
  }
  var cfg = await api('/validator/config', { headers: { 'X-Validator-Key': ident } });
  return { role: 'validator', key: ident, cfg: cfg, name: cfg.station };
}

$('form').onsubmit = async function (e) {
  e.preventDefault();
  var ident = $('ident').value.trim();
  var secret = $('secret').value;
  if (!ident) return say($('msg'), mode === 'signup' ? 'Enter your phone number.' : 'Enter your phone number or ID.', 'err');
  var btn = $('submit');
  btn.disabled = true;
  try {
    var session;
    if (mode === 'signup') {
      var name = $('name').value.trim();
      if (name.length < 2) throw new Error('Enter your full name.');
      var r = await api('/auth/register', { method: 'POST', body: { phone: ident, name: name, pin: secret } });
      session = { role: 'rider', token: r.token, name: r.name };
    } else {
      session = await signIn(ident, secret);
    }
    Session.set(session);
    go(Session.home(session.role));
  } catch (err) {
    say($('msg'), err.status === 401 ? GENERIC : err.message, 'err');
    btn.disabled = false;
  }
};

render();
