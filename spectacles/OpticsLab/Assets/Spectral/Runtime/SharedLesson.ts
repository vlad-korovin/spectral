import {SessionController} from 'SpectaclesSyncKit.lspkg/Core/SessionController';
import {SyncEntity} from 'SpectaclesSyncKit.lspkg/Core/SyncEntity';
import {StorageProperty} from 'SpectaclesSyncKit.lspkg/Core/StorageProperty';
import {SpectralLab} from './SpectralLab';
import {MATERIALS,LIGHTS,MaterialID,LightID} from '../Core/Materials';
import {LIGHTING_STYLES,LightingStyle} from '../Core/Lighting';
import {Command} from '../Core/Lesson';
/** Discrete settings have separate properties; moving the glass never owns the lighting store. */
@component
export class SharedLesson extends BaseScriptComponent {
 @allowUndefined
 @input lab!:SpectralLab;
 private material=StorageProperty.manualString('material','crown');
 private light=StorageProperty.manualString('light','white');
 private style=StorageProperty.manualString('style','soft');
 private lesson=StorageProperty.manualBool('lesson',false);
 private entity:SyncEntity;
 onAwake(){
  this.entity=new SyncEntity(this);
  for(const p of [this.material,this.light,this.style])this.entity.addStorageProperty(p);
  this.entity.addStorageProperty(this.lesson);
  this.createEvent('OnStartEvent').bind(()=>{
   this.lab.submitCommand=command=>this.write(command);
   const read=()=>{
    if(SessionController.getInstance().isSingleplayer())return;
    const m=this.material.currentOrPendingValue,l=this.light.currentOrPendingValue,s=this.style.currentOrPendingValue,e=this.lesson.currentOrPendingValue;
    if(MATERIALS.indexOf(m as MaterialID)>=0)this.lab.apply({kind:'material',value:m as MaterialID});
    if(LIGHTS.indexOf(l as LightID)>=0)this.lab.apply({kind:'light',value:l as LightID});
    if(LIGHTING_STYLES.indexOf(s as LightingStyle)>=0)this.lab.apply({kind:'style',value:s as LightingStyle});
    if(typeof e==='boolean')this.lab.apply({kind:'lesson',value:e});
   };
   this.material.onAnyChange.add(read);this.light.onAnyChange.add(read);this.style.onAnyChange.add(read);this.lesson.onAnyChange.add(read);this.entity.notifyOnReady(read);
  });
 }
 private write(command:Command){
  // Solo has no shared store to own; its controls must apply locally.
  if(SessionController.getInstance().isSingleplayer()){this.lab.apply(command);return;}
  if(!this.entity.canIModifyStore()){print('Wait for the shared lesson to connect.');return;}
  if(command.kind==='material')this.material.setPendingValue(command.value);
  else if(command.kind==='light')this.light.setPendingValue(command.value);
  else if(command.kind==='style')this.style.setPendingValue(command.value);
  else this.lesson.setPendingValue(command.value);
  this.lab.apply(command);
 }
}
