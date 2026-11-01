import {V,Plane,CRYSTAL,faces,trace,add,mul,sub,dot,unit,cross,receiverHit} from '../Core/Optics';
import {samples,materialLabel,coefficients} from '../Core/Materials';
import {Settings,DEFAULT_SETTINGS,parseVoice,Command,lessonText,RevisionGate} from '../Core/Lesson';
import {lightingPattern,lightingLabel,apertureRadiusCm,causticRadiusCm} from '../Core/Lighting';
import {IdleCrystalMotion} from '../Core/IdleMotion';
import {Interactable} from 'SpectaclesInteractionKit.lspkg/Components/Interaction/Interactable/Interactable';
import {InteractableManipulation} from 'SpectaclesInteractionKit.lspkg/Components/Interaction/InteractableManipulation/InteractableManipulation';
import {SIK} from 'SpectaclesInteractionKit.lspkg/SIK';
import {Interactor,InteractorInputType} from 'SpectaclesInteractionKit.lspkg/Core/Interactor/Interactor';
const v=(x:vec3):V=>[x.x,x.y,x.z];
const native=(x:V)=>new vec3(x[0],x[1],x[2]);
type ExitRay={o:V;d:V;slot:number};
const PALETTE_SIZE=256,INCIDENT_SLOT=255;

/** Lens adapter: SIK owns object transforms; this component only consumes them. */
@component
export class SpectralLab extends BaseScriptComponent {
 @allowUndefined
 @input glass!:SceneObject;
 @allowUndefined
 @input source!:SceneObject;
 @allowUndefined
 @input crystalVisual!:RenderMeshVisual;
 @allowUndefined
 @input raysVisual!:RenderMeshVisual;
 @allowUndefined
 @input patchVisual!:RenderMeshVisual;
 @allowUndefined
 @input label!:Text;
 @input enableRoomQuery:boolean=true;
 @input stableGlassVisibility:boolean=false;
 /** Developer option matching iOS's hidden Surface/Space choice. Space is the product default. */
 @input surfacePlacement:boolean=false;
 @allowUndefined
 @input worldMeshVisual!:RenderMeshVisual;
 settings:Settings={...DEFAULT_SETTINGS};
 submitCommand:((command:Command)=>void)|null=null;
 private lastKey=''; private nextTrace=0; private nextRoom=0;
 private exits:ExitRay[]=[]; private poseRevision=0; private active=false;
 private spectrumKey=''; private spectrum:ReturnType<typeof samples>=[];
 private roomSession:HitTestSession|null=null;
 private placementSession:HitTestSession|null=null; private placementBusy=false; private nextPlacementQuery=0;
 private placementHit:WorldQueryHitTestResult|null=null; private placementHitTime=-1;
 private placementPoint:vec3|null=null; private placementInteractor:Interactor|null=null;
 private placementListenersReady=false; private placed=false;
 private gate=new RevisionGate(); private alive=true; private roomBusy=false;
 private rayBuilder!:MeshBuilder; private patchBuilder!:MeshBuilder;
 private palette!:Texture; private paletteBytes=new Uint8Array(PALETTE_SIZE*4); private swatch=INCIDENT_SLOT;
 private frameWindow=0; private frames=0; private fps=0;
 private opticalRuns=0; private opticsHz=0; private costs:number[]=[]; private p50=0; private p95=0;
 private roomCallbacks=0; private roomHz=0; private tracedPaths=0; private rayVertices=0; private receiverSpots=0;
 private idle=new IdleCrystalMotion(); private idleBasePosition=vec3.zero(); private idleBaseRotation=quat.quatIdentity();
 private idleYaw=0; private idleCinema=0; private manipulating=false;
 private leftHand:any=null; private rightHand:any=null;
 private sourceOffset=vec3.zero(); private sourceBaseRotation=quat.quatIdentity();
 private status='Move the crystal and light with direct or indirect pinch.';
 private editorPrompt(device:string,editor:string){return global.deviceInfoSystem.isEditor()?editor:device;}
 onAwake(){
  this.createEvent('OnStartEvent').bind(()=>this.start());
  this.createEvent('OnDisableEvent').bind(()=>{this.active=false;this.gate.next();if(this.patchVisual)this.patchVisual.enabled=false;if(this.raysVisual)this.raysVisual.enabled=false;});
  this.createEvent('OnEnableEvent').bind(()=>{this.active=true;this.lastKey='';this.nextTrace=0;});
  this.createEvent('OnDestroyEvent').bind(()=>{this.alive=false;this.active=false;this.gate.next();});
 }
 private builder(){const b=new MeshBuilder([{name:'position',components:3},{name:'normal',components:3},{name:'texture0',components:2}]);b.topology=MeshTopology.Triangles;b.indexType=MeshIndexType.UInt16;return b;}
 private start(){
  print('Spectral inputs: glass='+(!!this.glass)+' source='+(!!this.source)+' crystalVisual='+(!!this.crystalVisual)+' raysVisual='+(!!this.raysVisual)+' patchVisual='+(!!this.patchVisual)+' label='+(!!this.label)+' worldMeshVisual='+(!!this.worldMeshVisual));
  if(!this.glass||!this.source||!this.crystalVisual||!this.raysVisual||!this.patchVisual||!this.label){print('Spectral: scene inputs missing; use the supplied scene.');return;}
  this.active=true;this.rayBuilder=this.builder();this.patchBuilder=this.builder();
  this.palette=ProceduralTextureProvider.createWithFormat(PALETTE_SIZE,1,TextureFormat.RGBA8Unorm);
  for(const visual of [this.raysVisual,this.patchVisual]){
   visual.mainPass.baseTex=this.palette;visual.mainPass.blendMode=BlendMode.Add;
   visual.mainPass.depthWrite=false;visual.mainPass.twoSided=true;
  }
  // World depth must occlude every spatial optical element. Disabling this made
  // the rays and glass read as a HUD overlay instead of content inside the room.
  this.raysVisual.mainPass.depthTest=true;
  this.raysVisual.setRenderOrder(2);
  this.patchVisual.mainPass.depthTest=true;
  this.patchVisual.enabled=false;this.receiverSpots=0;
  this.raysVisual.mesh=this.rayBuilder.getMesh();this.patchVisual.mesh=this.patchBuilder.getMesh();
  const b=this.builder();
  for(const face of faces(CRYSTAL))for(let i=1;i<face.vertices.length-1;i++)this.triangle(b,face.vertices[0],face.vertices[i],face.vertices[i+1],face.normal,100);
  this.crystalVisual.mesh=b.getMesh();b.updateMesh();
  this.wireCrystalMaterial();
  this.setupCrystalInteraction();
  this.setupHandDiagnostics();
  this.setupWorldPlacement();
  if(this.enableRoomQuery){try{const options=HitTestSessionOptions.create();options.filter=true;this.roomSession=require('LensStudio:WorldQueryModule').createHitTestSessionWithOptions(options);}catch(e){print('Room query unavailable. Caustics remain hidden.');}}
  this.room();
  this.frameWindow=getTime();
  this.createEvent('UpdateEvent').bind(()=>this.update());
 }
 /** Expose the real SIK tracking state so preview limitations are visible instead of looking like a dead interaction. */
 private setupHandDiagnostics(){
  try{
   this.leftHand=SIK.HandInputData.getHand('left');this.rightHand=SIK.HandInputData.getHand('right');
   this.leftHand.onHandFound.add(()=>{print('Spectral input: left hand tracked.');this.refreshLabel();});
   this.rightHand.onHandFound.add(()=>{print('Spectral input: right hand tracked.');this.refreshLabel();});
   this.leftHand.onHandLost.add(()=>{print('Spectral input: left hand lost.');this.refreshLabel();});
   this.rightHand.onHandLost.add(()=>{print('Spectral input: right hand lost.');this.refreshLabel();});
  }catch(e){print('Spectral input: SIK hand diagnostics unavailable; editor mouse interaction remains active.');}
 }
 private handState(){
  const state=(hand:any)=>!hand?'off':!hand.isTracked()?'--':hand.isPinching()?'pinch':'tracked';
  const prefix=global.deviceInfoSystem.isEditor()?'Input editor':'Input device';
  return `${prefix} · L ${state(this.leftHand)} · R ${state(this.rightHand)}`;
 }
 /**
  * iOS creates an ARAnchor from a camera ray. Spectacles has a world-tracked
  * coordinate system rather than ARKit anchors, so the equivalent is: acquire
  * an SIK world ray, optionally query room depth, then commit the resulting
  * world transform. After that commit InteractableManipulation owns the pose.
  */
 private setupWorldPlacement(){
  const glassTransform=this.glass.getTransform(),sourceTransform=this.source.getTransform();
  this.sourceOffset=sourceTransform.getWorldPosition().sub(glassTransform.getWorldPosition());
  this.sourceBaseRotation=sourceTransform.getWorldRotation();
  try{const options=HitTestSessionOptions.create();options.filter=true;this.placementSession=require('LensStudio:WorldQueryModule').createHitTestSessionWithOptions(options);}catch(e){print('Spectral placement: World Query unavailable; free-space placement remains active.');}
  this.bindPlacementInteractors();
  this.placed=false;this.glass.enabled=false;this.source.enabled=false;
  this.raysVisual.enabled=false;this.patchVisual.enabled=false;
  this.status=this.editorPrompt('Point into the room and pinch to place the crystal.','Preview: click empty space once to place the crystal.');
 }
 private bindPlacementInteractors(){
  if(this.placementListenersReady)return;
  const interactors=SIK.InteractionManager.getInteractorsByType(InteractorInputType.All);
  if(!interactors.length)return;
  for(const interactor of interactors)interactor.onTriggerEnd.add(target=>{
   // A release over UIKit belongs to that control (for example the Sync Kit
   // start menu or Lighting button). Only an untargeted room pinch places the
   // crystal, preventing UI taps from silently fixing a pose behind the panel.
   if(target===null)this.commitWorldPlacement(interactor);
  });
  this.placementListenersReady=true;
 }
 private updateWorldPlacement(now:number){
  this.bindPlacementInteractors();
  const interactor=SIK.InteractionManager.getTargetingInteractors().find(candidate=>candidate.isActive()&&candidate.isTargeting()&&candidate.startPoint!==null&&candidate.direction!==null)??null;
  this.placementInteractor=interactor;
  if(!interactor||!interactor.startPoint||!interactor.direction){this.placementPoint=null;this.status=this.editorPrompt('Point into the room and pinch to place the crystal.','Preview: move the pointer into the scene, then click empty space.');return;}
  const direction=interactor.direction.normalize(),start=interactor.startPoint;
  // Match iOS Space placement: 75 cm along the pointing ray, with the optical
  // solid's centre lowered by its 7.25 cm half-height.
  this.placementPoint=start.add(direction.uniformScale(75)).sub(vec3.up().uniformScale(7.25));
  this.status=this.surfacePlacement&&this.placementHit&&now-this.placementHitTime<.6?
   this.editorPrompt('Surface found · pinch to place.','Surface found · click to place.'):
   this.editorPrompt('Pinch to place freely in 3D space.','Preview: click empty space to place at the pointer ray.');
  if(!this.placementSession||this.placementBusy||now<this.nextPlacementQuery)return;
  this.nextPlacementQuery=now+.2;this.placementBusy=true;
  const rayStart=start.add(direction.uniformScale(5)),rayEnd=start.add(direction.uniformScale(300));
  this.placementSession.hitTest(rayStart,rayEnd,hit=>{this.placementBusy=false;if(this.placed||!this.alive)return;this.placementHit=hit;this.placementHitTime=getTime();});
 }
 private commitWorldPlacement(interactor:Interactor){
  if(this.placed||interactor!==this.placementInteractor||!this.placementPoint)return;
  const now=getTime(),freshSurface=this.surfacePlacement&&this.placementHit&&now-this.placementHitTime<.6;
  const position=freshSurface?this.placementHit!.position.add(this.placementHit!.normal.normalize().uniformScale(7.25)):this.placementPoint;
  let rotation=quat.quatIdentity();
  if(freshSurface){
   const normal=this.placementHit!.normal.normalize();
   const lookDirection=1-Math.abs(normal.dot(vec3.up()))<.01?vec3.forward():normal.cross(vec3.up()).normalize();
   rotation=quat.lookAt(lookDirection,normal);
  }
  const transform=this.glass.getTransform();transform.setWorldPosition(position);transform.setWorldRotation(rotation);
  const sourceTransform=this.source.getTransform();sourceTransform.setWorldPosition(position.add(rotation.multiplyVec3(this.sourceOffset)));sourceTransform.setWorldRotation(rotation.multiply(this.sourceBaseRotation));
  this.idleBasePosition=position;this.idleBaseRotation=rotation;this.idleYaw=0;this.idle.reset(now);
  this.placed=true;this.glass.enabled=true;this.source.enabled=true;this.lastKey='';
  this.status=this.editorPrompt('Pinch the crystal to move it in XYZ · use two hands to rotate or scale.','Preview: left-click + drag crystal to move · no Cmd key · WASD/Space/Ctrl moves view.');
  print(`Spectral placement: committed ${freshSurface?'surface':'free-space'} world pose.`);
 }
 /** Match the iOS idle choreography and keep SIK manipulation fully spatial. */
 private setupCrystalInteraction(){
  const transform=this.glass.getTransform(),now=getTime();
  this.idleBasePosition=transform.getWorldPosition();this.idleBaseRotation=transform.getWorldRotation();this.idle.reset(now);
  const control=this.glass.getComponent(Interactable.getTypeName()) as any;
  const manipulation=this.glass.getComponent(InteractableManipulation.getTypeName()) as InteractableManipulation;
  if(!control||!manipulation){print('Crystal requires SIK Interactable and InteractableManipulation.');return;}
  control.targetingMode=7;control.ignoreInteractionPlane=true;control.keepHoverOnTrigger=true;
  control.enableInstantDrag=true;control.isScrollable=true;control.allowMultipleInteractors=true;
  control.acceptableXDirections=true;control.acceptableYDirections=true;control.acceptableZDirections=true;
  control.useFilteredPinch=true;
  manipulation.setCanTranslate(true);manipulation.setCanRotate(true);manipulation.setCanScale(true);
  manipulation.enableStretchZ=true;
  manipulation.enableXTranslation=true;manipulation.enableYTranslation=true;manipulation.enableZTranslation=true;
  manipulation.onManipulationStart.add(()=>{this.manipulating=true;this.idle.pause(getTime());});
  manipulation.onManipulationEnd.add(()=>{
   const t=this.glass.getTransform(),offset=this.idle.offset;
   this.idleBasePosition=t.getWorldPosition().sub(new vec3(offset[0]*100,offset[1]*100,offset[2]*100));
   this.idleBaseRotation=t.getWorldRotation();this.idleYaw=0;this.manipulating=false;this.idle.pause(getTime());this.lastKey='';
  });
 }
 private updateIdle(now:number){
  if(this.manipulating)return;
  const frame=this.idle.step(now,true),offset=frame.offset,t=this.glass.getTransform();
  this.idleYaw+=frame.yawDelta;this.idleCinema=frame.cinema;
  t.setWorldPosition(this.idleBasePosition.add(new vec3(offset[0]*100,offset[1]*100,offset[2]*100)));
  t.setWorldRotation(this.idleBaseRotation.multiply(quat.angleAxis(this.idleYaw,vec3.up())));
  try{
   const pass=this.crystalVisual.mainMaterial.mainPass as any;
   if(pass&&pass.lightPeak!==undefined)pass.lightPeak=new vec3({white:0,red:640,green:540,blue:450}[this.settings.light],this.idleCinema,0);
  }catch(e){}
 }
 /** Native world-mesh depth occlusion: real surfaces hide the glass and receive the caustic, while the teaching ray remains legible. */
 private room(){
  if(!this.worldMeshVisual)return;
  try{
   const provider=this.worldMeshVisual.mesh.control as WorldRenderObjectProvider;
   provider.enableWorldMeshesTracking=true;provider.useNormals=true;provider.meshClassificationFormat=MeshClassificationFormat.None;
   for(let i=0;i<global.scene.getRootObjectsCount();i++){
    const tracking=global.scene.getRootObject(i).getComponent('Component.DeviceTracking');
    if(tracking){tracking.worldOptions.enableWorldMeshesTracking=true;break;}
   }
}catch(e){print('World mesh unavailable. Depth occlusion stays off.');}
  }
  /** CrystalRefraction shader wiring: no-op on the old Glass.mat (no sellmeierB param). */
  private wireCrystalMaterial(){
   try{
    const pass=this.crystalVisual.mainMaterial.mainPass as any;
    if(!pass)return;
    // Apply visibility policy even while Lens Studio is still resolving the
    // custom material parameters during a hot reload.
    // The convex mesh is generated from half-space intersections at runtime.
    // Render both sides so a winding disagreement on one clipped polygon cannot
    // make the transparent solid disappear when the viewer tilts their head.
    pass.blendMode=BlendMode.Normal;pass.depthWrite=false;pass.depthTest=!this.stableGlassVisibility;pass.twoSided=true;
    if(pass.sellmeierB===undefined)return;
    const {b,c}=coefficients(this.settings.material);
    pass.sellmeierB=new vec4(b[0]||0,b[1]||0,b[2]||0,b[3]||0);
    pass.sellmeierC=new vec4(c[0]||0,c[1]||0,c[2]||0,c[3]||0);
    pass.lightPeak=new vec3({white:0,red:640,green:540,blue:450}[this.settings.light],this.idleCinema,0);
    if(!pass.cameraTex){try{const cam=requireAsset('Device Camera Texture') as any;if(cam)pass.cameraTex=cam;}catch(e){}}
    // The optional visibility override remains available for diagnosing coarse
    // simulator meshes. Production keeps it off so room depth can occlude the
    // glass, rays and caustic consistently.
   }catch(e){}
  }
 command(command:Command){if(this.submitCommand)this.submitCommand(command);else this.apply(command);}
 apply(command:Command){
  if(this.settings[command.kind]===command.value)return;
  if(command.kind==='material')this.settings.material=command.value;
  else if(command.kind==='light')this.settings.light=command.value;
  else if(command.kind==='style')this.settings.style=command.value;
  else this.settings.lesson=command.value;
  this.lastKey='';
 }
 transcript(text:string,final:boolean){const command=parseVoice(text,final);if(command)this.command(command);}
 private clear(b:MeshBuilder){if(b.getIndicesCount()>0)b.eraseIndices(0,b.getIndicesCount());if(b.getVerticesCount()>0)b.eraseVertices(0,b.getVerticesCount());}
 private triangle(b:MeshBuilder,a:V,c:V,d:V,n:V,scale=1){
  const i=b.getVerticesCount();for(const p of [a,c,d])b.appendVerticesInterleaved([...mul(p,scale),...n,(this.swatch+.5)/PALETTE_SIZE,.5]);b.appendIndices([i,i+1,i+2]);
 }
 private tube(a:V,b:V,width=.045){ // centimetres; triangular ribbons on two planes
  const delta=sub(b,a);if(dot(delta,delta)<1e-8)return;
  const d=unit(delta),u=mul(unit(cross(d,Math.abs(d[1])<.9?[0,1,0]:[1,0,0])),width),w=mul(unit(cross(d,u)),width);
  for(const offset of [u,w]){const p=add(a,offset),q=sub(a,offset),r=add(b,offset),s=sub(b,offset);const n=unit(cross(d,offset));this.triangle(this.rayBuilder,p,q,r,n);this.triangle(this.rayBuilder,r,q,s,n);}
 }
 private update(){
  const now=getTime();if(!this.active)return;
  this.frames++;this.report(now);
  if(!this.placed){this.updateWorldPlacement(now);return;}
  this.updateIdle(now);
  if(now<this.nextTrace)return;
  this.nextTrace=now+.05; // bounded 20 Hz optical updates, display/hand tracking remain independent
  const t=this.glass.getTransform(),matrix=t.getWorldTransform(),inverse=t.getInvertedWorldTransform();
  const sourceTransform=this.source.getTransform(),source=sourceTransform.getWorldPosition(),sourceMatrix=sourceTransform.getWorldTransform();
  const position=t.getWorldPosition(),rotation=t.getWorldRotation(),scale=t.getWorldScale();
  // Uniform scaling only: normals and metric conversion remain well-defined.
  if(Math.min(scale.x,scale.y,scale.z)<=0||Math.abs(scale.x-scale.y)>1e-3||Math.abs(scale.x-scale.z)>1e-3){this.status='Use uniform two-hand scaling.';this.raysVisual.enabled=false;this.patchVisual.enabled=false;this.gate.next();this.lastKey='';this.refreshLabel();return;}
  const sourceRotation=sourceTransform.getWorldRotation();
  const key=[...v(source),sourceRotation.x,sourceRotation.y,sourceRotation.z,sourceRotation.w,...v(position),rotation.x,rotation.y,rotation.z,rotation.w,...v(scale),this.settings.material,this.settings.light,this.settings.style,this.settings.lesson].join(',');
  const changed=key!==this.lastKey;
  if(!changed){this.queryRoom(now);return;}
  const costStart=getTime();
  this.lastKey=key;this.poseRevision=this.gate.next();this.exits=[];
  this.wireCrystalMaterial();
  this.patchVisual.enabled=false;
  const target:V=[0,.072,0],sourceCenter=v(source);
  const sourceAxis=(axis:vec3)=>unit(sub(v(sourceMatrix.multiplyPoint(axis)),sourceCenter));
  const right=sourceAxis(new vec3(1,0,0)),up=sourceAxis(new vec3(0,1,0));
  const pattern=lightingPattern(this.settings.style),radius=apertureRadiusCm(this.settings.style);
  const spectrumKey=this.settings.material+':'+this.settings.light;
  if(spectrumKey!==this.spectrumKey){this.spectrum=samples(this.settings.material,this.settings.light,31);this.spectrumKey=spectrumKey;}
  const table=this.spectrum;
  const paths:{sample:typeof table[number];path:ReturnType<typeof trace>;origin:V;slot:number}[]=[];
  for(const aperture of pattern){
   const originWorld=add(sourceCenter,add(mul(right,aperture.x*radius),mul(up,aperture.y*radius)));
   const origin=mul(v(inverse.multiplyPoint(native(originWorld))),.01);
   if(dot(sub(target,origin),sub(target,origin))<1e-10)continue;
   const direction=unit(sub(target,origin));
   for(const sample of table)paths.push({sample,path:trace(origin,direction,sample.index),origin,slot:paths.length});
  }
  if(!paths.length){this.raysVisual.enabled=false;this.status='Move the source outside the glass.';this.refreshLabel();return;}
  const world=(p:V)=>v(matrix.multiplyPoint(native(mul(p,100))));
  this.clear(this.rayBuilder);this.paletteBytes.fill(0);
  const targetNM={white:550,red:640,green:540,blue:450}[this.settings.light];
  const referenceIndex=Math.round((targetNM-420)/260*30),reference=paths[referenceIndex];
  const incidentColor=mul(table.reduce((sum,s)=>add(sum,s.color),[0,0,0] as V),1/pattern.length);
  this.paletteBytes.set([...incidentColor.map(c=>Math.round(Math.min(1,c)*204)),255],INCIDENT_SLOT*4);
  const exits=this.exits;
  for(const item of paths){
    const {sample,path,origin,slot}=item;this.swatch=slot;
    const color=mul(sample.color,(path.escaped?path.energy:1)/pattern.length);
    this.paletteBytes.set([...color.map(c=>Math.round(Math.min(1,Math.max(0,c*5))*255)),255],slot*4);
    if(Math.max(...color)<1/1275)continue;
    this.swatch=INCIDENT_SLOT;if(path.points.length>1)this.tube(world(origin),world(path.points[1]));this.swatch=slot;
    // Rays are a teaching overlay, not claims of visible beams in clean air.
    for(let i=1;i<path.points.length-1;i++)this.tube(world(path.points[i]),world(path.points[i+1]));
    if(path.escaped){const a=world(path.origin),b=world(add(path.origin,path.direction));const dir=unit(sub(b,a));exits.push({o:a,d:dir,slot});this.tube(a,add(a,mul(dir,70)));}
  }
  (this.palette.control as ProceduralTextureProvider).setPixels(0,0,PALETTE_SIZE,1,this.paletteBytes);
  this.raysVisual.enabled=this.rayBuilder.getVerticesCount()>0;
  if(this.raysVisual.enabled)this.rayBuilder.updateMesh();
  this.tracedPaths=paths.length;this.rayVertices=this.rayBuilder.getVerticesCount();
  this.status=this.settings.lesson?lessonText(reference.path,reference.sample.nm):'Pinch and move in 3D · use two hands to rotate or scale';
  this.opticalRuns++;this.costs.push((getTime()-costStart)*1000);if(this.costs.length>64)this.costs.shift();
  this.refreshLabel();
  this.queryRoom(now);
 }
 private report(now:number){
  const elapsed=now-this.frameWindow;if(elapsed<.5)return;
  this.fps=this.frames/elapsed;this.opticsHz=this.opticalRuns/elapsed;this.roomHz=this.roomCallbacks/elapsed;
  if(this.costs.length){const sorted=this.costs.slice().sort((a,b)=>a-b);this.p50=sorted[Math.floor((sorted.length-1)*.5)];this.p95=sorted[Math.floor((sorted.length-1)*.95)];}
  this.frames=0;this.opticalRuns=0;this.roomCallbacks=0;this.costs=[];this.frameWindow=now;this.refreshLabel();
 }
 private refreshLabel(){
  if(!this.label)return;
  const optics=this.opticsHz>.05?`${this.p50.toFixed(2)} ms p50 · ${this.p95.toFixed(2)} ms p95 · ${this.opticsHz.toFixed(0)} Hz`:'sleeping · pose unchanged';
  this.label.text=`SPECTRAL · ${materialLabel(this.settings.material)} · ${lightingLabel(this.settings.style)}\n${this.fps.toFixed(0)} fps · ${this.tracedPaths} paths · 31 λ / 420–680 nm\nOptics ${optics}\nMesh ${this.rayVertices} verts · room ${this.receiverSpots} @ ${this.roomHz.toFixed(1)} Hz\n${this.handState()}\n${this.status}\nVoice: “Spectral halo light” · “Spectral explain”`;
 }
 private queryRoom(now:number){
  const exits=this.exits,revision=this.poseRevision;
  if(!this.roomSession||this.roomBusy||now<this.nextRoom||!exits.length)return;
  this.nextRoom=now+.2;this.roomBusy=true;
  const center=exits[Math.floor(exits.length/2)];
  this.roomSession.hitTest(native(center.o),native(add(center.o,mul(center.d,300))),hit=>{
    this.roomBusy=false;if(!this.alive||!this.active||!this.gate.accepts(revision))return;
    this.roomCallbacks++;
    this.patchVisual.enabled=false;if(!hit)return;
    const normal=unit(v(hit.normal)),point=v(hit.position),plane:Plane={n:normal,h:dot(normal,point)};
    const u=unit(cross(normal,Math.abs(normal[1])<.9?[0,1,0]:[1,0,0])),w=cross(normal,u);
    this.clear(this.patchBuilder);
    let spots=0;const radius=causticRadiusCm(this.settings.style);
    for(const ray of exits){
      this.swatch=ray.slot;
      // Lens units are cm here; max hit distance 300 cm. Only a 20 cm local plane patch is supported.
      const p=receiverHit(ray.o,ray.d,plane,300);if(!p||dot(sub(p,point),sub(p,point))>400)continue;
      const c=add(p,mul(normal,.15));
      for(let i=0;i<12;i++){
        const disk=(angle:number)=>add(c,add(mul(u,Math.cos(angle)*radius),mul(w,Math.sin(angle)*radius)));
        this.triangle(this.patchBuilder,c,disk(i*Math.PI/6),disk((i+1)*Math.PI/6),normal);
      }spots++;
    }
    this.receiverSpots=spots;if(this.patchBuilder.getVerticesCount()){this.patchBuilder.updateMesh();this.patchVisual.enabled=true;}
    this.refreshLabel();
  });
 }
}
