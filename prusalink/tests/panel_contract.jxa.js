// macOS JavaScriptCore regression checks using the actual host-injected bridge.
// No Minerva process, profile, vault, printer, browser or network is accessed.
// The native transport and DOM are inert test adapters; this is NOT UI/live acceptance.
// Usage: osascript -l JavaScript tests/panel_contract.jxa.js <panel.html> <minerva_bridge.gd>
ObjC.import('Foundation');
ObjC.import('stdlib');
function run(paths) {
  function read(path) {
    const value = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    if (!value) throw new Error('Cannot read test source');
    return value.js;
  }
  function assert(condition, label) { if (!condition) throw new Error(label); }
  const panel = read(paths[0]).split('<script>')[1].split('</script>')[0];
  const bridge = read(paths[1]).split('<script>')[1].split('</script>')[0];
  const nodes = new Map(), notifications = [], requests = [];
  let configured = false, rejectSet = false, rejectNotify = false, nextId = 0;
  let state = 'PRINTING', thumbnailCalls = 0, interruptThumbnail = false;
  const listeners = new Map();
  function node() {
    return {value:'',hidden:false,disabled:false,textContent:'',className:'',clientWidth:400,
      style:{setProperty(){}},children:[],handlers:new Map(),
      append(...children){this.children.push(...children);},replaceChildren(){this.children=[];},
      addEventListener(event, handler){this.handlers.set(event,handler);},
      setAttribute(){},removeAttribute(){},focus(){},reset(){},getContext(){return null;}};
  }
  const document = {
    visibilityState:'visible',getElementById(id){if(!nodes.has(id))nodes.set(id,node());return nodes.get(id);},
    createElement(){return node();},addEventListener(event,handler){listeners.set(event,handler);}
  };
  const printer={id:'printer1',slot:1,name:'Lab',host:'http://printer.invalid',user:'maker',has_password:true,secret_handle:'prusalink_printer1'};
  const window = {addEventListener(){},sendIpcMessage(encoded){
    const request=JSON.parse(encoded);requests.push(request.type);
    let result={},success=true;
    if(request.type==='minerva.call') {
      const tool=request.payload.tool;
      let body={};
      if(tool.endsWith('_list_printers'))body={printers:configured?[printer]:[]};
      else if(tool.endsWith('_configure_printer')){configured=true;body=printer;}
      else if(tool.endsWith('_status'))body={state,job_id:42,job_file:'part.bgcode',progress_percent:50,time_printing_s:100,time_remaining_s:100,axis_z_mm:15,total_height_mm:30,layer_height_mm:0.15,storage_available:true,thumbnail_ref:'/thumb/l/usb/part.bgcode'};
      else if(tool.endsWith('_thumbnail')){
        thumbnailCalls++;
        if(interruptThumbnail){interruptThumbnail=false;document.visibilityState='hidden';body={available:true,mime:'image/png',reference:'/thumb/l/usb/part.bgcode',offset:0,total_bytes:24584,base64:'AAAA'.repeat(8192),next_offset:24576};}
        else body={available:true,mime:'image/png',reference:'/thumb/l/usb/part.bgcode',offset:0,total_bytes:8,base64:'iVBORw0KGgo=',next_offset:null};
      } else throw new Error('Unexpected panel tool');
      result={content:[{type:'text',text:JSON.stringify(body)}]};
    } else if(request.type==='capability:secrets:set:prusalink_printer1'){
      assert(request.payload.value==='public-invalid-input','only test input enters inert secret transport');
      success=!rejectSet;result={handle:'plugin/prusalink/prusalink_printer1',status:'created'};
    } else if(request.type==='capability:host.notify'){
      notifications.push(request.payload);success=!rejectNotify;result={};
    } else throw new Error('Unexpected native bridge request');
    window.minerva._ipcReply({id:request.id,success,result,error_message:'test rejection'});
  }};
  // JXA lacks browser TextEncoder/timers; these adapters supply only bridge plumbing.
  function Encoder(){} Encoder.prototype.encode=function(text){return text.split('');};
  const setTimer=()=>1,clearTimer=()=>{};
  new Function('window','TextEncoder','crypto','setTimeout','clearTimeout','console',bridge)(window,Encoder,{randomUUID:()=>String(++nextId)},setTimer,clearTimer,{log(){},error(){}});
  const api=new Function('window','document','setTimeout','clearTimeout','setInterval','clearInterval',panel+'\nreturn {notifyTransition,notificationFailures,previousStates,cards,status,poll,refreshList};')(window,document,setTimer,clearTimer,setTimer,clearTimer);
  async function flush(){for(let i=0;i<20;i++)await Promise.resolve();}
  return (async()=>{
    await flush();
    for(const [id,value] of [['name','Lab'],['host','printer.invalid'],['user','maker'],['password','public-invalid-input']])document.getElementById(id).value=value;
    await document.getElementById('printer-form').handlers.get('submit')({preventDefault(){}});
    await flush();
    assert(document.getElementById('test').disabled===false,'unwrapped secret set enables Test');
    assert(document.getElementById('password').value==='','password field cleared');
    assert(!document.getElementById('message').className.includes('error'),'successful save does not show an error');
    assert(api.cards.get('printer1').layerText.textContent.includes('100 of 200'),'0.15 mm layer count preserved');
    assert(api.cards.get('printer1').image.hidden===false&&api.cards.get('printer1').placeholder.hidden===true,'successful thumbnail selects image');
    api.previousStates.clear();notifications.length=0;
    await api.notifyTransition(printer,'PRINTING');await api.notifyTransition(printer,'FINISHED');await api.notifyTransition(printer,'FINISHED');
    assert(notifications.length===1&&!api.notificationFailures.has('printer1'),'unwrapped notify {} succeeds once per transition');
    rejectNotify=true;await api.notifyTransition(printer,'ERROR');await api.notifyTransition(printer,'ERROR');
    assert(notifications.length===2&&api.notificationFailures.has('printer1'),'failed notification is visible and never repeats');rejectNotify=false;
    const card=api.cards.get('printer1');card.thumbnailKey=null;interruptThumbnail=true;
    await api.status('printer1');assert(card.thumbnailKey===null,'hidden thumbnail retrieval clears incomplete key');
    const before=thumbnailCalls;document.visibilityState='visible';listeners.get('visibilitychange')();await flush();
    assert(thumbnailCalls>before&&!card.image.hidden,'visible panel retries interrupted thumbnail');
    document.visibilityState='hidden';const count=requests.length;await api.poll();assert(requests.length===count,'hidden page does not poll');document.visibilityState='visible';
    rejectSet=true;document.getElementById('password').value='public-invalid-input';
    await document.getElementById('printer-form').handlers.get('submit')({preventDefault(){}});
    assert(document.getElementById('message').className.includes('error')&&document.getElementById('password').value==='','rejected secret set is visible and field clears');
    console.log('PASS panel contract: actual host bridge, save/notify fulfillment, transition deduplication, geometry and thumbnail resume; inert DOM/native adapters only');
  })().catch(error=>{console.log('FAIL panel contract: '+error.message);$.exit(1);});
}
