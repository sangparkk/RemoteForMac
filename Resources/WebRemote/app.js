'use strict';
const $ = id => document.getElementById(id);
const uuid = () => {const b=crypto.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;const h=[...b].map(x=>x.toString(16).padStart(2,'0')).join('');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;};
let token='',client='',sequence=0,connected=false,busy=false,queue=[],lastSend=0,pendingDisconnect=false;
let manualDisconnect=false;
let deviceId='';
let keyboardRequest=null,inputSession=null,composing=false,pendingDraft=null;
try {
  token=localStorage.getItem('remotetv-token')||'';
  deviceId=localStorage.getItem('remotetv-device')||'';
} catch {}
if(!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(deviceId)){
  deviceId=uuid();
  try{localStorage.setItem('remotetv-device',deviceId);}catch{}
}
if (/^#[a-f0-9]{64}$/.test(location.hash)) {token=location.hash.slice(1);try{localStorage.setItem('remotetv-token',token);}catch{}history.replaceState(null,'',location.pathname);}
function status(text){$('message').textContent=text;$('padStatus').textContent=text;}
function render(){ $('connect').textContent='이 Mac 연결';$('connect').disabled=!token;$('connect').hidden=connected||!token;$('pairArea').hidden=connected||!!token;$('changeCode').hidden=connected||!token;$('state').textContent=connected?'Mac 연결됨':'연결 대기';$('light').classList.toggle('on',connected);$('disconnect').hidden=!connected;$('controls').hidden=!connected; }
function saveToken(value){token=value;try{value?localStorage.setItem('remotetv-token',value):localStorage.removeItem('remotetv-token');}catch{}render();}
$('changeCode').onclick=()=>{saveToken('');status('Mac의 새 웹 등록 코드를 입력하세요.');};
$('pair').onclick=async()=>{const code=$('pairCode').value.trim();if(!/^\d{6}$/.test(code)){status('Mac에 표시된 숫자 6자리를 입력하세요.');return;}$('pair').disabled=true;try{const result=await request('/pair',{code});saveToken(result.token);$('pairCode').value='';status('등록 완료 · Mac에 연결 중…');manualDisconnect=false;autoConnect();}catch{status('코드가 틀렸거나 만료되었습니다. Mac에 표시된 현재 코드를 입력하세요.');}finally{$('pair').disabled=false;}};
function showDirection(){const reversed=$('reverse').checked;$('padReverse').setAttribute('aria-pressed',String(reversed));$('padReverse').setAttribute('aria-label',reversed?'스크롤 반대 방향':'스크롤 기본 방향');document.querySelector(`input[name="scrollDirection"][value="${reversed?'reversed':'normal'}"]`).checked=true;try{localStorage.setItem('remotetv-scroll',String(reversed));}catch{}}
try{$('reverse').checked=localStorage.getItem('remotetv-scroll')==='true';}catch{}
$('reverse').onchange=showDirection;for(const option of document.querySelectorAll('input[name="scrollDirection"]'))option.onchange=()=>{$('reverse').checked=option.value==='reversed';showDirection();};$('padReverse').onclick=()=>{$('reverse').checked=!$('reverse').checked;showDirection();};showDirection();
function closeKeyboard(){keyboardRequest=null;inputSession=null;pendingDraft=null;composing=false;$('typing').blur();$('keyboardArea').hidden=true;$('typing').value='';$('keyboard').setAttribute('aria-label','키보드 열기');}
function failed(text){connected=false;queue=[];pendingDisconnect=false;closeKeyboard();render();status(text);}
async function request(path,body){const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),3500);try{const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify(body),cache:'no-store',signal:controller.signal,keepalive:true});if(!response.ok){if(response.status===403&&path!=='/pair')saveToken('');throw Error(response.status===403?'Mac의 새 등록 코드로 다시 등록해 주세요.':'연결이 종료되었습니다. 다시 연결하세요.');}return await response.json();}finally{clearTimeout(timeout);}}
function enqueue(action,coalesce=false){if(!connected)return;if(coalesce&&queue.length){const last=queue[queue.length-1];if(last.type===action.type&&(action.type==='text'||(action.type==='touch'&&last.points.length===action.points.length))){queue[queue.length-1]=action;return;}}queue.push(action);if(queue.length>60){queue=[{type:'cancel'},{type:'disconnect'}];pendingDisconnect=true;status('연결 지연으로 입력을 중지합니다.');}}
async function pump(){if(busy||!connected)return;const now=performance.now();if(!queue.length&&now-lastSend<1000)return;busy=true;const actions=queue.splice(0,64);if(!actions.length)actions.push({type:'heartbeat'});lastSend=now;const ending=actions.some(a=>a.type==='disconnect');try{const events=await request('/commands',{client,sequence:++sequence,actions});for(const event of events)receive(event);if(ending)failed('연결 해제됨 · 다시 연결할 수 있습니다.');}catch(error){const reconnect=pendingDisconnect&&!manualDisconnect&&!document.hidden;failed(error.name==='AbortError'?'응답이 지연되어 제어를 중단했습니다. 다시 연결하세요.':error.message);if(reconnect)setTimeout(autoConnect,0);}finally{busy=false;if(ending&&!manualDisconnect&&!document.hidden)setTimeout(autoConnect,0);}}
async function connect(){if(busy||connected||document.hidden)return;if(!token){status('Mac에 표시된 웹 등록 코드를 먼저 입력하세요.');return;}busy=true;$('connect').disabled=true;status('Mac에 연결 중…');try{client=uuid();sequence=0;queue=[];const kind=/iPhone/i.test(navigator.userAgent)?'iPhone':/iPad/i.test(navigator.userAgent)?'iPad':'';await request('/connect',{client,device:deviceId,kind});connected=true;pendingDisconnect=false;render();status('연결됨 · 터치패드를 열어 주세요.');}catch(error){failed(error.message);}finally{busy=false;$('connect').disabled=false;}}
$('connect').onclick=()=>{manualDisconnect=false;connect();};
function disconnect(){if(!connected)return;queue=[{type:'cancel'},{type:'endText'},{type:'disconnect'}];pendingDisconnect=true;closeKeyboard();pump();}
$('disconnect').onclick=()=>{manualDisconnect=true;disconnect();};
$('openPad').onclick=()=>{document.body.classList.add('pad-open');window.scrollTo(0,0);$('home').hidden=true;$('padScreen').hidden=false;status('Mac 연결됨 · 터치패드 사용 중');};
$('back').onclick=()=>{enqueue({type:'cancel'});enqueue({type:'endText'});closeKeyboard();document.body.classList.remove('pad-open');$('home').hidden=false;$('padScreen').hidden=true;pump();};
for(const button of document.querySelectorAll('[data-service]'))button.onclick=()=>{enqueue({type:'activate',service:button.dataset.service});pump();};
for(const button of document.querySelectorAll('[data-key]'))button.onclick=()=>{enqueue({type:'cancel'});enqueue({type:'key',key:button.dataset.key});pump();};
const pad=$('pad');let tracking=false;
function points(touches){const rect=pad.getBoundingClientRect();return [...touches].filter(t=>t.target===pad||pad.contains(t.target)).map(t=>({x:t.clientX-rect.left,y:t.clientY-rect.top}));}
function touch(list,coalesce){enqueue({type:'touch',points:list,x:Number($('sensitivity').value),y:$('reverse').checked?-1:1},coalesce);}
pad.addEventListener('touchstart',event=>{event.preventDefault();if(!connected||pendingDisconnect)return;tracking=true;touch(points(event.touches),false);pump();},{passive:false});
pad.addEventListener('touchmove',event=>{event.preventDefault();if(tracking){touch(points(event.touches),true);pump();}},{passive:false});
pad.addEventListener('touchend',event=>{event.preventDefault();if(!tracking)return;touch(points([...event.touches,...event.changedTouches]),false);touch(points(event.touches),false);if(!event.touches.length)tracking=false;pump();},{passive:false});
pad.addEventListener('touchcancel',event=>{event.preventDefault();tracking=false;enqueue({type:'cancel'});pump();},{passive:false});
for(const name of ['gesturestart','gesturechange','gestureend'])pad.addEventListener(name,event=>event.preventDefault(),{passive:false});
pad.addEventListener('contextmenu',event=>event.preventDefault());
function cancelGesture(){tracking=false;enqueue({type:'cancel'});pump();}
window.addEventListener('orientationchange',cancelGesture);
$('keyboard').onclick=()=>{if(!connected)return;cancelGesture();if(!$('keyboardArea').hidden){enqueue({type:'endText'});closeKeyboard();pump();return;}$('keyboardArea').hidden=false;$('keyboard').setAttribute('aria-label','키보드 닫기');$('typing').value='';$('typing').focus();keyboardRequest=uuid();inputSession=null;pendingDraft=null;enqueue({type:'keyboard',request:keyboardRequest});status('키보드 열림 · Mac 입력창 확인 중…');pump();};
function snapshot(){const t=$('typing');return {text:t.value,selection:{location:t.selectionStart,length:t.selectionEnd-t.selectionStart},marked:composing?{location:0,length:t.value.length}:null};}
function textChanged(){const value=snapshot();if(!inputSession){if(keyboardRequest)pendingDraft=value;return;}enqueue({type:'text',session:inputSession,snapshot:value},true);}
$('typing').addEventListener('compositionstart',()=>{composing=true;});
$('typing').addEventListener('compositionend',()=>{composing=false;textChanged();});
$('typing').addEventListener('input',textChanged);
$('typing').addEventListener('beforeinput',event=>{if(event.inputType==='deleteContentBackward'&&!$('typing').value&&inputSession){event.preventDefault();enqueue({type:'backspace',session:inputSession});pump();}});
function submit(){if(!inputSession||composing)return;textChanged();enqueue({type:'submit',session:inputSession});closeKeyboard();pump();}
$('typing').addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.isComposing){event.preventDefault();submit();}});$('submit').onclick=submit;
function receive(event){if(event.baseline){const b=event.baseline;if(!keyboardRequest||b.request.toLowerCase()!==keyboardRequest.toLowerCase())return;keyboardRequest=null;inputSession=b.session;let value=b.snapshot;if(pendingDraft){const start=value.selection.location,end=start+value.selection.length;value={text:value.text.slice(0,start)+pendingDraft.text+value.text.slice(end),selection:{location:start+pendingDraft.selection.location,length:pendingDraft.selection.length},marked:null};}pendingDraft=null;$('typing').value=value.text;$('typing').setSelectionRange(value.selection.location,value.selection.location+value.selection.length);status('Mac 입력창에 입력 중');textChanged();}
else if(event.keyboardUnavailable){keyboardRequest=null;inputSession=null;pendingDraft=null;status(event.keyboardUnavailable.message);}
else if(event.notice){status(event.notice._0);}
else if(event.disconnectRequested){failed('Mac에서 연결을 해제했습니다.');}
else if(event.textEnded&&!keyboardRequest&&inputSession){closeKeyboard();status('입력 연결 종료 · 다른 입력창을 클릭한 뒤 다시 여세요.');}}
function autoConnect(){if(manualDisconnect||!token||document.hidden||connected)return;if(busy){setTimeout(autoConnect,350);return;}connect();}
document.addEventListener('visibilitychange',()=>{if(document.hidden)disconnect();else autoConnect();});
window.addEventListener('pagehide',disconnect);
function frame(){pump();requestAnimationFrame(frame);}requestAnimationFrame(frame);setInterval(pump,1000);render();if(token){status('등록된 Mac에 자동 연결 중…');autoConnect();}

function fitViewport(){document.documentElement.style.setProperty('--app-height',`${window.visualViewport?.height||innerHeight}px`);}window.visualViewport?.addEventListener('resize',fitViewport);window.addEventListener('resize',fitViewport);fitViewport();
