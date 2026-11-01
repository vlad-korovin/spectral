import {SpectralLab} from './SpectralLab';
/** ASR is Spectacles-only. Desktop retains the spatial controls. */
@component
export class VoiceControl extends BaseScriptComponent {
 @allowUndefined
 @input lab!:SpectralLab;
 @input listenOnDevice:boolean=false;
 private module:AsrModule|null=null;
 private active=false;
 private started=false;
 private generation=0;
 private stopping:Promise<void>|null=null;
 onAwake(){
  this.createEvent('OnStartEvent').bind(()=>{this.started=true;this.active=true;this.start();});
  this.createEvent('OnEnableEvent').bind(()=>{this.active=true;if(this.started)this.start();});
  this.createEvent('OnDisableEvent').bind(()=>{this.active=false;this.stop();});
  this.createEvent('OnDestroyEvent').bind(()=>{this.active=false;this.stop();});
 }
 private start(){
  if(!this.active||!this.listenOnDevice||!this.lab||this.module)return;
  if(this.stopping){this.stopping.then(()=>this.start());return;}
  const generation=++this.generation;
  try{
   const module:AsrModule=require('LensStudio:AsrModule');
   const options=AsrModule.AsrTranscriptionOptions.create();
   options.silenceUntilTerminationMs=700;options.mode=AsrModule.AsrMode.Balanced;
   options.onTranscriptionUpdateEvent.add(e=>{
    if(this.active&&generation===this.generation)this.lab.transcript(e.text,e.isFinal);
   });
   options.onTranscriptionErrorEvent.add(code=>{
    if(this.active&&generation===this.generation)print(`Speech unavailable (${code}). Use spatial controls.`);
   });
   this.module=module;module.startTranscribing(options);
  }catch(e){this.module=null;print('Speech unavailable in this runtime. Use spatial controls.');}
 }
 private stop(){
  ++this.generation;
  const module=this.module;this.module=null;
  if(!module)return;
  try{this.stopping=module.stopTranscribing().catch(()=>{}).then(()=>{this.stopping=null;});}
  catch(e){this.stopping=null;}
 }
}
