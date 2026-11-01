import {Interactable} from 'SpectaclesInteractionKit.lspkg/Components/Interaction/Interactable/Interactable';
import WorldCameraFinderProvider from 'SpectaclesInteractionKit.lspkg/Providers/CameraProvider/WorldCameraFinderProvider';
import {SpectralLab} from './SpectralLab';
import {MATERIALS,LIGHTS} from '../Core/Materials';
import {LIGHTING_STYLES,lightingLabel} from '../Core/Lighting';
/** World-space controls: SIK on device; explicit ray/plane mouse picking in editor. */
@component
export class LessonButton extends BaseScriptComponent {
 @allowUndefined
 @input lab!:SpectralLab;
 @input action:string='material';
 @allowUndefined
 @input feedbackLabel!:Text;
 private feedback='';
 private resolvedAction(){
  // Lens Studio 5.15 can rewrite this generic string input to its class default
  // when a scene imported from YAML is saved. Stable object names make the
  // supplied scene immune to that serialization behavior.
  const name=this.sceneObject.name.toLowerCase();
  if(name.indexOf('lighting')>=0||name.indexOf('light colour')>=0)return 'style';
  if(name.indexOf('explain')>=0)return 'lesson';
  if(name.indexOf('material')>=0)return 'material';
  return this.action;
 }
 onAwake(){this.createEvent('OnStartEvent').bind(()=>{
  const control=this.sceneObject.getComponent(Interactable.getTypeName());
  if(!control||!this.lab){print('LessonButton requires Interactable and SpectralLab.');return;}
  // Scene serialization in Lens Studio 5.15 can restore these package inputs
  // to old values. Enforce the intended direct + indirect interaction policy
  // at runtime so saving the project cannot silently shrink button behavior.
  const interaction=control as any;
  interaction.targetingMode=7;
  interaction.ignoreInteractionPlane=true;
  interaction.keepHoverOnTrigger=true;
  interaction.useFilteredPinch=true;
  // Trigger on pinch/poke start so the response feels immediate. Waiting for
  // release made a successful indirect pinch look like an unresponsive button.
  const editor=global.deviceInfoSystem.isEditor();
  // Do not also process SIK mouse triggers: a single click must advance once.
  control.onTriggerStart.add(()=>{if(!editor)this.activate();});
  if(editor){
   const camera=WorldCameraFinderProvider.getInstance();
   this.createEvent('TouchStartEvent').bind(event=>{
    if(!this.sceneObject.isEnabledInHierarchy)return;
    const p=event.getTouchPosition();
    const inverse=this.sceneObject.getTransform().getInvertedWorldTransform();
    const a=inverse.multiplyPoint(camera.screenSpaceToWorldSpace(p.x,p.y,0));
    const b=inverse.multiplyPoint(camera.screenSpaceToWorldSpace(p.x,p.y,1000));
    const dz=b.z-a.z;
    if(Math.abs(dz)<1e-6)return;
    const t=-a.z/dz;
    if(t<0||t>1)return;
    const x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t;
    // Same 40 x 20 local-space rectangle as the scene's button collider.
    if(Math.abs(x)<=20&&Math.abs(y)<=10)this.activate();
   });
  }
  this.refreshFeedback();
  if(this.feedbackLabel)this.createEvent('UpdateEvent').bind(()=>this.refreshFeedback());
 });}
 private activate(){
  const action=this.resolvedAction();
  if(action==='material')this.lab.command({kind:'material',value:MATERIALS[(MATERIALS.indexOf(this.lab.settings.material)+1)%MATERIALS.length]});
  else if(action==='light')this.lab.command({kind:'light',value:LIGHTS[(LIGHTS.indexOf(this.lab.settings.light)+1)%LIGHTS.length]});
  else if(action==='style')this.lab.command({kind:'style',value:LIGHTING_STYLES[(LIGHTING_STYLES.indexOf(this.lab.settings.style)+1)%LIGHTING_STYLES.length]});
  else this.lab.command({kind:'lesson',value:!this.lab.settings.lesson});
  print(`Spectral button: ${action}; material=${this.lab.settings.material}, lighting=${this.lab.settings.style}, explain=${this.lab.settings.lesson}`);
  this.refreshFeedback();
 }
 private refreshFeedback(){
  if(!this.feedbackLabel||!this.lab)return;
  const action=this.resolvedAction();
  const value=action==='style'?`Lighting · ${lightingLabel(this.lab.settings.style)}`:action==='lesson'?(this.lab.settings.lesson?'Explain · On':'Explain · Off'):'';
  if(value&&value!==this.feedback){this.feedback=value;this.feedbackLabel.text=value;}
 }
}
