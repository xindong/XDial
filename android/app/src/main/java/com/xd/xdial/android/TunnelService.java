package com.xd.xdial.android;

import android.app.*;
import android.content.*;
import android.net.*;
import android.os.*;
import java.net.NetworkInterface;
import java.util.concurrent.*;
import org.json.*;
import libbox.*;

/** Android owns OS resources; the shared controller owns intent/epoch/retries. */
public final class TunnelService extends VpnService {
 public static volatile String state="未连接", probeResult="", surveyResult="";
 public static volatile boolean active, settingUp;
 public static volatile long selectionRevision;
 public static volatile String tailscaleStatus="", setupMessage="";
 private String setupLine="";
 private volatile OnlineProfileImport profileImport;
 private volatile Network importNetwork;
 private volatile LinkProperties importLinks;
 private Runnable importTimeout;
 private final Handler mainHandler=new Handler(Looper.getMainLooper());
 private void invalidateImport(Network network,LinkProperties value,boolean lost){
  OnlineProfileImport request=profileImport;Network captured=importNetwork;
  if(request!=null && captured!=null && ((lost&&captured.equals(network)) || (!lost&&(!captured.equals(network)||(value!=null&&!value.equals(importLinks)))))){
   request.cancelled=true;Libbox_ runtime=request.runtime;if(runtime!=null)runtime.cancelPreparation();
  }
 }
 private ScheduledFuture<?> statusRefresh, switchRefresh, retireSwitch;
 private volatile boolean switching;
 private boolean coreReady;
 private long switchToken;
 private String sessionDNS="",sessionInterfaces="",sessionInterface="";
 private int sessionInterfaceIndex;
 private final java.util.concurrent.atomic.AtomicLong switchRequests=new java.util.concurrent.atomic.AtomicLong();
 private final ScheduledExecutorService worker=Executors.newSingleThreadScheduledExecutor();
 private final ExecutorService probes=Executors.newSingleThreadExecutor();
 private final ConnectionController lifecycle=Libbox.newConnectionController();
 private volatile Libbox_ core;
 private ParcelFileDescriptor tunnel;
 private ConnectivityManager connectivity;
 private Network underlay;
 private LinkProperties links;
 private NetworkCapabilities capabilities;
 private boolean watching,blocked;
 private volatile boolean destroyed,stopRequested;
 private long coreEpoch, preparationSockets;
 private ScheduledFuture<?> retry;
 private ScheduledFuture<?> vpnReleaseTimeout;
 private boolean waitingVpnRelease;
 private String stage="配置读取";
 private final java.util.concurrent.atomic.AtomicLong protectedSockets=new java.util.concurrent.atomic.AtomicLong();
 private final java.util.concurrent.atomic.AtomicLong protectionFailures=new java.util.concurrent.atomic.AtomicLong();
 private final java.util.concurrent.atomic.AtomicLong observedNetworkRevision=new java.util.concurrent.atomic.AtomicLong();
 private void enqueue(Runnable action) {
  if(destroyed)return;
  try {worker.execute(()->{if(!destroyed)action.run();});}catch(RejectedExecutionException ignored){}
 }
 private final ConnectivityManager.NetworkCallback networks=new ConnectivityManager.NetworkCallback() {
  @Override public void onAvailable(Network network) {invalidateImport(network,null,false);observedNetworkRevision.incrementAndGet();enqueue(()->{underlay=network;links=null;capabilities=null;blocked=false;});}
  @Override public void onCapabilitiesChanged(Network network,NetworkCapabilities value) {enqueue(()->{
   if(!network.equals(underlay))return;
   int validated=NetworkCapabilities.NET_CAPABILITY_VALIDATED;
   if(capabilities!=null && !capabilities.hasCapability(validated) && value.hasCapability(validated)){
    lifecycle.networkBecameReachable();
   }
   capabilities=value;observe();
  });}
  @Override public void onLinkPropertiesChanged(Network network,LinkProperties value) {invalidateImport(network,value,false);observedNetworkRevision.incrementAndGet();enqueue(()->{if(network.equals(underlay)){links=value;observe();}});}
  @Override public void onBlockedStatusChanged(Network network,boolean value) {if(value)invalidateImport(network,null,true);observedNetworkRevision.incrementAndGet();enqueue(()->{if(network.equals(underlay)){blocked=value;observe();}});}
  @Override public void onLost(Network network) {invalidateImport(network,null,true);observedNetworkRevision.incrementAndGet();enqueue(()->{if(network.equals(underlay)){underlay=null;links=null;capabilities=null;lifecycle.observeUnderlay("");reconcile();}});}
 };
 private final ConnectivityManager.NetworkCallback defaultNetwork=new ConnectivityManager.NetworkCallback(){
  @Override public void onAvailable(Network network){enqueue(TunnelService.this::acquireSystemNetwork);}
  @Override public void onCapabilitiesChanged(Network network,NetworkCapabilities value){enqueue(TunnelService.this::acquireSystemNetwork);}
  @Override public void onLost(Network network){enqueue(TunnelService.this::acquireSystemNetwork);}
 };
 @Override public void onCreate(){super.onCreate();connectivity=getSystemService(ConnectivityManager.class);}
 @Override public int onStartCommand(Intent intent,int flags,int id) {
  String action=intent==null?"":intent.getAction();
  if("cancel-import".equals(action)){
   String requestID=intent.getStringExtra("request");OnlineProfileImport current=profileImport;
   if(current!=null&&current.id.equals(requestID)){cancelPreparation();enqueue(()->{state="未连接";finish();});}
   else if(!active)stopSelf();return START_NOT_STICKY;
  }
  final OnlineProfileImport incoming="import-profile".equals(action)?OnlineProfileImport.find(intent.getStringExtra("request")):null;
  if("import-profile".equals(action)&&(incoming==null||incoming.cancelled||active)){if(incoming!=null)incoming.complete();if(!active)stopSelf();return START_NOT_STICKY;}
  if("stop".equals(action)){cancelPreparation();enqueue(()->{state="未连接";finish();});return START_NOT_STICKY;}
  if("switch-scenario".equals(action)){
   final String target=intent.getStringExtra("scenario");final long request=switchRequests.incrementAndGet();
   Libbox_ current=core;if(switching&&current!=null)current.cancelPreparation();
   enqueue(()->switchScenario(request,target));return START_NOT_STICKY;
  }
  if("tailscale-login".equals(action)){enqueue(()->{
   if(core==null||!settingUp)return;
   try{tailscaleStatus=core.beginTailscaleLogin("tailscale-"+setupLine);setupMessage="请打开浏览器完成登录";}
   catch(Exception error){setupMessage="暂未取得登录地址，请检查网络后重试";}
  });return START_NOT_STICKY;}
  if("tailscale-logout".equals(action)){enqueue(()->{
   if(core==null||!settingUp)return;
   try{core.tailscaleLogout("tailscale-"+setupLine);tailscaleStatus="";setupMessage="已退出登录";}
   catch(Exception error){setupMessage="退出登录未完成，请检查网络后重试";}
  });return START_NOT_STICKY;}
  if("tailscale-select".equals(action)){final String node=intent.getStringExtra("node");enqueue(()->{
   if(core==null||!settingUp)return;
   try{
    String fresh=core.tailscaleStatus("tailscale-"+setupLine);
    ProfileStore store=new ProfileStore(this);
    String updated=Libbox.selectTailscaleExit(store.load(),setupLine,fresh,node);
    // Retire the setup identity owner before publishing a data-session binding.
    stopCore();store.save(updated);MobileSelection.invalidate();state="Tailscale 场景已保存，可拨动拨盘连接";finish();
   }catch(Exception error){setupMessage="节点暂不可用或无法保存，请刷新后重试";if(core==null){state="无法保存场景，原配置保留";finish();}}
  });return START_NOT_STICKY;}
  if("probe".equals(action)){
   enqueue(()->{if(core!=null){final long epoch=coreEpoch;probes.execute(()->{
    String result=ConnectionProbe.run(connectivity);
    enqueue(()->{if(core!=null && coreEpoch==epoch){probeResult=result;android.util.Log.i("XDialProbe",result);}});
   });}});return START_NOT_STICKY;
  }
  if("identity-test".equals(action)){
   if((getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)!=0)enqueue(()->{
    try{probeResult=IdentityStore.verify(this)+"\n"+ProfileStore.verify(this);}catch(Exception error){probeResult="安全存储验收失败";}
    android.util.Log.i("XDialProbe",probeResult);
   });return START_NOT_STICKY;
  }
  if("diagnose".equals(action)){enqueue(this::diagnose);return START_NOT_STICKY;}
  if(!active)stopRequested=false;
  NotificationManager nm=getSystemService(NotificationManager.class);
  nm.createNotificationChannel(new NotificationChannel("connection","连接状态",NotificationManager.IMPORTANCE_LOW));
  PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE);
  PendingIntent stop=PendingIntent.getService(this,1,new Intent(this,TunnelService.class).setAction("stop"),PendingIntent.FLAG_IMMUTABLE);
  startForeground(1,new Notification.Builder(this,"connection").setSmallIcon(android.R.drawable.stat_sys_upload_done)
   .setContentTitle("XDial").setContentText("连接服务运行中 · 可随时断开").setContentIntent(open).setOngoing(true)
   .addAction(new Notification.Action.Builder(null,"断开",stop).build()).build());
  enqueue(()->{
   if(active){if(incoming!=null)incoming.complete();return;}
   if(incoming!=null&&incoming.cancelled){incoming.complete();finish();return;}
   profileImport=incoming;
   if(stopRequested){state="未连接";finish();return;}
   settingUp="tailscale-setup".equals(action);setupLine=settingUp?intent.getStringExtra("line"):"";tailscaleStatus="";setupMessage="";
   synchronized(ProfileStore.class){active=true;}probeResult="";surveyResult="";lifecycle.requestConnection(true);state="等待可用网络";
   if(profileImport!=null){importTimeout=()->{if(profileImport!=null){cancelPreparation();enqueue(()->{state="配置下载超时";finish();});}};mainHandler.postDelayed(importTimeout,35000);}
   acquireSystemNetwork();
  });
  return START_NOT_STICKY;
 }
 private void acquireSystemNetwork(){
  if(destroyed||!active||stopRequested||watching)return;
  try {
    Network current=connectivity.getActiveNetwork();NetworkCapabilities caps=current==null?null:connectivity.getNetworkCapabilities(current);
    if(caps!=null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)){
     // Closing our last fd and Android withdrawing its VPN Network are separate
     // events. Never bypass a still-visible VPN or rank interfaces to get out.
     if(!waitingVpnRelease){
      logTunnelOwnership("waiting-vpn-release");state="等待系统释放 VPN";
      connectivity.registerDefaultNetworkCallback(defaultNetwork);waitingVpnRelease=true;
      vpnReleaseTimeout=worker.schedule(()->{if(waitingVpnRelease){state="系统仍有 VPN 连接，请先断开后重试";finish();}},20,TimeUnit.SECONDS);
     }
     return;
    }
    stopWaitingForVpnRelease();
    // Android selects its best matching network. No interface/transport ranking.
    connectivity.requestNetwork(new NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
     .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),networks);
    watching=true;
  }catch(Exception error){state="无法取得系统网络，请检查 VPN 状态";finish();}
 }
 private void stopWaitingForVpnRelease(){
  if(vpnReleaseTimeout!=null){vpnReleaseTimeout.cancel(false);vpnReleaseTimeout=null;}
  if(waitingVpnRelease){try{connectivity.unregisterNetworkCallback(defaultNetwork);}catch(Exception ignored){}waitingVpnRelease=false;}
 }
 private void observe(){
  if(underlay==null || links==null || capabilities==null)return;
  boolean usable=!blocked && links.getInterfaceName()!=null && !links.getLinkAddresses().isEmpty() && !links.getDnsServers().isEmpty()
   && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN);
  // LinkProperties equality includes DNS, addresses and routes; identity stays
  // process-local and is never emitted to logs or sent as product telemetry.
  lifecycle.observeUnderlay(usable?underlay.toString()+":"+links.toString():"");reconcile();
 }
 private void reconcile(){
  if(destroyed || !active)return;
  try {
   JSONObject snapshot=new JSONObject(lifecycle.snapshot());long epoch=snapshot.getLong("epoch");
   if(core!=null && coreEpoch!=epoch)stopCore();
   String phase=snapshot.getString("phase");
   if(phase.equals("waiting_network")){probeResult="";state="网络已断开，等待恢复";setUnderlyingNetworks(new Network[0]);return;}
   if(phase.equals("failed")){finish();return;}
   long attempt=lifecycle.nextAttempt(SystemClock.elapsedRealtime());
   if(attempt!=0)connect(attempt);
  }catch(Exception error){state="连接状态异常，请重新连接";finish();}
 }
 private void connect(final long epoch){
  state="正在连接";probeResult="";coreEpoch=epoch;
  try {
   stage="配置读取";
   String ssid="";
   if(checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)==android.content.pm.PackageManager.PERMISSION_GRANTED) {
    android.net.wifi.WifiManager wifi=(android.net.wifi.WifiManager)getApplicationContext().getSystemService(WIFI_SERVICE);
    android.net.wifi.WifiInfo info=wifi.getConnectionInfo();
    if(info!=null && !android.net.wifi.WifiManager.UNKNOWN_SSID.equals(info.getSSID())) {
     ssid=info.getSSID();if(ssid.startsWith("\"") && ssid.endsWith("\"")) ssid=ssid.substring(1,ssid.length()-1);
    }
   }
   String profile=profileImport==null?new ProfileStore(this).load():Libbox.profileLibraryRuntime(profileImport.library);
   stage="系统网络";
   final Network captured=underlay;
   if(captured==null || links==null || capabilities==null)throw new java.net.SocketException("Underlay unavailable");
   NetworkInterface nic=NetworkInterface.getByName(links.getInterfaceName());
   if(nic==null)throw new java.net.SocketException("Interface unavailable");
   stage="配置编译";
   JSONArray systemDNS = new JSONArray();
   for(java.net.InetAddress server : links.getDnsServers()) systemDNS.put(server.getHostAddress());
   stage="核心初始化";
   core=Libbox.new_(new Callback(){
    public void onStatusChanged(String json){}
    public void onError(long code,String message){enqueue(()->{
     if(core==null || !active || coreEpoch!=epoch)return;
     attemptFailed(epoch,code==Libbox.ErrCodeTransientNetwork,"连接错误（"+code+"）");
    });}
   });
   core.setSecureStateStore(new IdentityStore(this));
   core.setStablePacketIngress(!settingUp);
   core.setSocketProtector(fd->{
    try{
     if(!protect((int)fd))throw new IllegalStateException("Socket protection denied");
     try(ParcelFileDescriptor duplicate=ParcelFileDescriptor.fromFd((int)fd)){captured.bindSocket(duplicate.getFileDescriptor());}
     protectedSockets.incrementAndGet();
    }catch(Exception error){protectionFailures.incrementAndGet();throw error;}
   });
   JSONArray snapshots = new JSONArray();
   JSONObject facts = new JSONObject();
   facts.put("mtu", nic.getMTU());
   int interfaceFlags = (nic.isUp()?1:0) | (nic.isLoopback()?4:0) | (nic.isPointToPoint()?8:0) | (nic.supportsMulticast()?16:0);
   facts.put("flags", interfaceFlags);
   JSONArray prefixes = new JSONArray();
   for(LinkAddress address : links.getLinkAddresses()) prefixes.put(address.getAddress().getHostAddress().split("%")[0]+"/"+address.getPrefixLength());
   facts.put("addresses", prefixes);
   JSONObject snapshot = new JSONObject();
   snapshot.put("name", nic.getName()); snapshot.put("index", nic.getIndex());
   snapshot.put("type", capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)?"wifi":capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)?"cellular":"other");
   snapshot.put("facts", facts); snapshots.put(snapshot);
   core.setNetworkInterfaces(snapshots.toString());
   core.setDefaultInterface(nic.getName(),nic.getIndex());
   if(profileImport!=null){
    OnlineProfileImport request=profileImport;importNetwork=captured;importLinks=links;request.runtime=core;
    if(request.cancelled||stopRequested)throw new java.io.InterruptedIOException("Import cancelled");
    stage="下载配置来源";state="正在下载配置（未接管流量）";long before=protectedSockets.get();
    String preview=core.fetchAndroidProfilePreview(request.library,request.url,request.line,request.name,request.source,systemDNS.toString(),getNoBackupFilesDir().getAbsolutePath());
    if(request.cancelled||stopRequested||!importLinks.equals(connectivity.getLinkProperties(captured)))throw new java.io.InterruptedIOException("Import network changed");
    request.result=preview;android.util.Log.i("XDialSourceImport","prepared=true protected="+(protectedSockets.get()-before)+" failures="+protectionFailures.get());
    state="未连接";finish();return;
   }
   if(!settingUp){
    final long observationRevision=observedNetworkRevision.get();
    MobileSelection selection=MobileSelection.get(this);long survey=selection.beginSurvey();String country="";
    boolean queried=selection.needsCountry(ssid);long beforeSurvey=protectedSockets.get();
    if(queried){
     stage="观察网络地区";state="正在判断网络地区";
     try{country=core.probeAndroidUnderlayCountry(systemDNS.toString(),6000);}
     catch(Exception unavailable){/* Unknown observation preserves the selection. */}
    }
    if(stopRequested)throw new java.io.InterruptedIOException("Stopped");
    // Callbacks queue behind preparation: read current OS facts before using an
    // observation, so a result from a departed network cannot select a scene.
    if(observationRevision!=observedNetworkRevision.get()||!links.equals(connectivity.getLinkProperties(captured)))throw new java.net.SocketException("Underlay changed during survey");
    selection.observeBeforeConnect(survey,ssid,country);
    profile=new ProfileStore(this).load();
    surveyResult=queried?(country.isEmpty()?"网络地区未查到，保留场景":"网络地区："+country):"";
    android.util.Log.i("XDialSurvey","queried="+queried+" found="+!country.isEmpty()+" protected="+(protectedSockets.get()-beforeSurvey));
    state="正在连接";
   }
   stage="准备离线规则";
   long beforePreparation=protectedSockets.get();
   String config;
   if(settingUp){
    config=Libbox.generateAndroidTailscaleSetupConfig(profile,setupLine,systemDNS.toString(),getNoBackupFilesDir().getAbsolutePath());
   }else{
    StartupResult prepared=core.prepareAndroidConfigResult(profile,systemDNS.toString(),getNoBackupFilesDir().getAbsolutePath());
    if(!prepared.getMessage().isEmpty()){attemptFailed(epoch,prepared.getRetryable(),"准备配置失败");return;}
    config=prepared.getValue();
   }
   preparationSockets=protectedSockets.get()-beforePreparation;
   if(stopRequested)throw new java.io.InterruptedIOException("Stopped");
   if(settingUp){
    stage="准备 Tailscale 登录";core.startStandalone(config);
    lifecycle.completeAttempt(epoch,true,false,SystemClock.elapsedRealtime());state="Tailscale 账号设置（未接管流量）";
    refreshTailscale(epoch);return;
   }
   JSONObject generated=new JSONObject(config);
   JSONArray inbounds=generated.getJSONArray("inbounds"); JSONObject tun=null;
   for(int i=0;i<inbounds.length();i++) if(inbounds.getJSONObject(i).getString("type").equals("tun")) tun=inbounds.getJSONObject(i);
   if(tun==null) throw new IllegalStateException("No TUN");
   Builder builder=new Builder().setSession("XDial").setMtu(tun.getInt("mtu"));
   JSONArray addresses=tun.getJSONArray("address");
   for(int i=0;i<addresses.length();i++) { String[] cidr=addresses.getString(i).split("/"); builder.addAddress(cidr[0],Integer.parseInt(cidr[1])); }
   builder.addRoute("0.0.0.0",0).addRoute("::",0).addDnsServer("198.18.0.2");
   builder.setUnderlyingNetworks(new Network[]{captured});
   stage="建立 TUN";
   // Keep the OS TUN across unavailable-network intervals. Stop its sole reader
   // before starting the next core; never run two gVisor stacks on the same fd.
   if(tunnel==null)tunnel=builder.establish();
   if(tunnel==null)throw new IllegalStateException("VPN permission revoked");
   setUnderlyingNetworks(new Network[]{captured});core.setTunFD(tunnel.getFd());
   sessionDNS=systemDNS.toString();sessionInterfaces=snapshots.toString();sessionInterface=nic.getName();sessionInterfaceIndex=nic.getIndex();
   stage="启动数据面";
   StartupResult started=core.startAndroidSessionResult(profile,config,sessionDNS);
   if(!started.getMessage().isEmpty()){
    attemptFailed(epoch,started.getRetryable(),"启动数据面失败");return;
   }
   logTunnelOwnership("connected-ingress");
   if(stopRequested){state="未连接";finish();return;}
   awaitReady(epoch,profile,systemDNS.toString(),SystemClock.elapsedRealtime()+30000);
  }catch(Exception error){
   if(profileImport!=null){state="配置下载未完成，原配置保留";finish();return;}
   attemptFailed(epoch,error instanceof java.net.SocketException,stage+"失败（"+error.getClass().getSimpleName()+"）");
  }
 }
 private void attemptFailed(long epoch,boolean retryable,String message){
  stopCore();
  if(stopRequested){state="未连接";finish();return;}
  lifecycle.completeAttempt(epoch,false,retryable,SystemClock.elapsedRealtime());
  try{
   JSONObject result=new JSONObject(lifecycle.snapshot());
   String phase=result.getString("phase");
   if(phase.equals("backoff")){
    state="网络暂不可用，正在重试";
    if(retry!=null)retry.cancel(false);
    retry=worker.schedule(this::reconcile,Math.max(1,result.getLong("retry_at_ms")-SystemClock.elapsedRealtime()),TimeUnit.MILLISECONDS);
   }else if(phase.equals("waiting_network")){
    state="等待网络恢复";
   }else{state=message;finish();}
  }catch(JSONException invalid){state=message;finish();}
 }
 private void refreshTailscale(long epoch){
  if(core==null||!settingUp||coreEpoch!=epoch)return;
  try{tailscaleStatus=core.tailscaleStatus("tailscale-"+setupLine);}
  catch(Exception error){tailscaleStatus="";setupMessage="暂时无法读取账号状态";}
  statusRefresh=worker.schedule(()->refreshTailscale(epoch),2000,TimeUnit.MILLISECONDS);
 }
 private void awaitReady(long epoch,String profile,String systemDNS,long deadline){
  if(core==null||coreEpoch!=epoch||!active)return;
  if(stopRequested){state="未连接";finish();return;}
  try{
   if(core.androidSessionReady(profile)){
    coreReady=true;MobileSelection.get(this).connected(true);lifecycle.completeAttempt(epoch,true,false,SystemClock.elapsedRealtime());state="已连接";
    Libbox_ committed=core;String base=getNoBackupFilesDir().getAbsolutePath();
    probes.execute(()->{try{android.util.Log.i("XDialRuleRefresh",committed.refreshAndroidRuleSets(profile,systemDNS,base));}catch(Exception ignored){/* Valid cache and traffic remain usable. */}});
    return;
   }
   if(SystemClock.elapsedRealtime()>=deadline){attemptFailed(epoch,true,"出口连接超时");return;}
   state="正在验证出口连接";statusRefresh=worker.schedule(()->awaitReady(epoch,profile,systemDNS,deadline),1000,TimeUnit.MILLISECONDS);
  }catch(Exception error){state="出口未就绪，请检查 Tailscale 登录、授权和节点状态";finish();}
 }
 private boolean switchCurrent(long request,long epoch,long networkRevision){
  return !destroyed&&!stopRequested&&active&&core!=null&&coreReady&&coreEpoch==epoch
   &&switchRequests.get()==request&&observedNetworkRevision.get()==networkRevision;
 }
 private void switchScenario(long request,String target){
  if(request!=switchRequests.get()||stopRequested||destroyed)return;
  abortSwitch();
  if(core==null||!coreReady||settingUp){state="请等待连接就绪后选择场景";return;}
  try{
   MobileSelection selection=MobileSelection.get(this);switchToken=selection.proposeConnected(target);
   if(switchToken==0){selectionRevision++;state="已连接 · 手动选择";return;}
   // A no-op above leaves the drain timer intact; a real candidate first
   // retires the retained source so only two generations can own leases.
   if(retireSwitch!=null){retireSwitch.cancel(false);retireSwitch=null;}
   core.retireCommittedSwitch();
   String profile=selection.candidate(switchToken);
   if(core.androidSwitchRequiresReconnect(profile)){
    if(stopRequested||request!=switchRequests.get()){abortSwitch();return;}
    selection.commitReconnect(switchToken);switchToken=0;selectionRevision++;
    state="线路身份变化，正在重新连接";stopCore();
    if(tunnel!=null){tunnel.close();tunnel=null;}logTunnelOwnership("switch-reconnect");
    if(stopRequested){state="未连接";finish();return;}
    lifecycle.requestConnection(false);lifecycle.requestConnection(true);reconcile();return;
   }
   final long epoch=coreEpoch,revision=observedNetworkRevision.get();switching=true;
   state="正在准备场景 · 原连接继续使用";logTunnelOwnership("switch-preparing");
   core.prepareAndroidSwitch(profile,sessionDNS,getNoBackupFilesDir().getAbsolutePath(),sessionInterfaces,sessionInterface,sessionInterfaceIndex);
   awaitSwitch(request,epoch,revision,profile,SystemClock.elapsedRealtime()+30000);
  }catch(Exception failure){
   abortSwitch();
   if(core==null){state=stopRequested?"未连接":"场景重新连接失败，请重试";finish();}
   else if(!stopRequested)state="场景准备失败 · 原连接继续使用";
  }
 }
 private void awaitSwitch(long request,long epoch,long revision,String profile,long deadline){
  if(!switchCurrent(request,epoch,revision)){abortSwitch();if(!stopRequested)state="场景准备已取消 · 原连接继续使用";return;}
  try{
   if(!core.androidPreparedSwitchReady(profile)){
    if(SystemClock.elapsedRealtime()>=deadline)throw new java.io.IOException("Candidate readiness timeout");
    switchRefresh=worker.schedule(()->awaitSwitch(request,epoch,revision,profile,deadline),500,TimeUnit.MILLISECONDS);return;
   }
   if(!switchCurrent(request,epoch,revision))throw new java.io.InterruptedIOException("Stale candidate");
   MobileSelection.get(this).commitConnected(switchToken,core);
   switchToken=0;switching=false;switchRefresh=null;selectionRevision++;state="已连接";logTunnelOwnership("switch-committed");
   final Libbox_ committed=core;
   retireSwitch=worker.schedule(()->{retireSwitch=null;if(core==committed)try{committed.retireCommittedSwitch();logTunnelOwnership("switch-retired");}catch(Exception error){state="场景清理异常，请重新连接";finish();}},1,TimeUnit.SECONDS);
   String dns=sessionDNS,base=getNoBackupFilesDir().getAbsolutePath();
   probes.execute(()->{try{android.util.Log.i("XDialRuleRefresh",committed.refreshAndroidRuleSets(profile,dns,base));}catch(Exception ignored){}});
  }catch(MobileSelection.SelectionRollbackException failure){state="场景保存异常，请重新连接";finish();}
  catch(Exception failure){abortSwitch();if(!stopRequested)state="场景切换失败 · 原连接继续使用";}
 }
 private void abortSwitch(){
  if(switchRefresh!=null){switchRefresh.cancel(false);switchRefresh=null;}
  if(switchToken!=0){
   if(core!=null)try{core.abortPreparedSwitch();}catch(Exception ignored){}
   try{MobileSelection.get(this).abortConnected(switchToken);}catch(Exception ignored){}
   switchToken=0;
  }
  switching=false;
 }
 private void diagnose(){
  try{
   JSONObject facts=core==null?new JSONObject():new JSONObject(core.diagnostics());JSONObject safe=new JSONObject();
   for(String key:new String[]{"running","gvisor_compiled","tun_fd_ready"})safe.put(key,facts.opt(key));
   if(core!=null)safe.put("routed_traffic",new JSONObject(core.trafficTotals()));
   safe.put("session_kind",settingUp?"setup":"traffic");safe.put("preparation_protected_sockets",preparationSockets);safe.put("protected_sockets",protectedSockets.get());safe.put("protection_failures",protectionFailures.get());
   safe.put("lifecycle",new JSONObject(lifecycle.snapshot()));android.util.Log.i("XDialDiagnostics",safe.toString());
  }catch(Exception ignored){}
 }
 private void stopCore(){
  coreReady=false;abortSwitch();
  if(retireSwitch!=null){retireSwitch.cancel(false);retireSwitch=null;}
  if(statusRefresh!=null){statusRefresh.cancel(false);statusRefresh=null;}
  tailscaleStatus="";
  if(core!=null){Libbox_ previous=core;core=null;try{previous.stop();}catch(Exception ignored){}}
  try{MobileSelection.get(this).connected(false);}catch(Exception ignored){}
 }
 private void cleanup(){
  if(importTimeout!=null){mainHandler.removeCallbacks(importTimeout);importTimeout=null;}
  stopWaitingForVpnRelease();
  lifecycle.requestConnection(false);if(retry!=null){retry.cancel(false);retry=null;}
  if(watching){try{connectivity.unregisterNetworkCallback(networks);}catch(Exception ignored){}watching=false;}
  stopCore();
  if(tunnel!=null){try{tunnel.close();}catch(Exception ignored){}tunnel=null;}
  logTunnelOwnership("released");
  underlay=null;links=null;capabilities=null;active=false;settingUp=false;setupLine="";tailscaleStatus="";setupMessage="";probeResult="";
  OnlineProfileImport completed=profileImport;profileImport=null;importNetwork=null;importLinks=null;if(completed!=null)completed.complete();
 }
 private void logTunnelOwnership(String phase){
  if((getApplicationInfo().flags&android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE)==0)return;
  int count=0;String[] descriptors=new java.io.File("/proc/self/fd").list();
  if(descriptors==null)return;
  for(String descriptor:descriptors)try{
   String target=android.system.Os.readlink("/proc/self/fd/"+descriptor);
   if(target.equals("/dev/tun")||target.equals("/dev/net/tun"))count++;
  }catch(Exception ignored){}
  android.util.Log.i("XDialLifecycle","phase="+phase+" tun_descriptors="+count);
 }
 private void finish(){cleanup();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();}
 private void cancelPreparation(){stopRequested=true;OnlineProfileImport request=profileImport;if(request!=null)request.cancelled=true;switchRequests.incrementAndGet();Libbox_ preparing=core;if(preparing!=null)preparing.cancelPreparation();}
 @Override public void onRevoke(){cancelPreparation();enqueue(()->{state="VPN 授权已撤销";finish();});}
 @Override public void onDestroy(){destroyed=true;cancelPreparation();probes.shutdownNow();worker.execute(this::cleanup);worker.shutdown();super.onDestroy();}
}
