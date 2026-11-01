const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const scene=fs.readFileSync(path.join(__dirname,'../OpticsLab/Assets/Scene.scene'),'utf8');
const runtime=fs.readFileSync(path.join(__dirname,'../OpticsLab/Assets/Spectral/Runtime/SpectralLab.ts'),'utf8');
const buttonRuntime=fs.readFileSync(path.join(__dirname,'../OpticsLab/Assets/Spectral/Runtime/LessonButton.ts'),'utf8');
const crystalShader=fs.readFileSync(path.join(__dirname,'../OpticsLab/Assets/Spectral/Shaders/CrystalRefraction.customCode'),'utf8');
const component=id=>scene.match(new RegExp(`- !<ScriptComponent/${id}>[\\s\\S]*?(?=\\n- !<)`))?.[0]||'';
const object=id=>scene.match(new RegExp(`- !<SceneObject/${id}>[\\s\\S]*?(?=\\n- !<)`))?.[0]||'';

test('the three spatial controls have stable role names and scripts',()=>{
 assert.match(object('3106b699-3708-5fd7-b71c-30d6f862bae4'),/Name: Material[\s\S]*!<own> 435cbeec-b9db-53c4-afac-8c5451327049/);
 assert.match(object('0789c14f-5d72-57fe-8106-544c42a57e3f'),/Name: Lighting style[\s\S]*!<own> 9f340924-fe80-56a9-9fa5-8a0c908c7c63/);
 assert.match(object('ea3645b7-9e65-5ab7-8d83-5fd2fdfaee31'),/Name: Explain[\s\S]*!<own> 86774e00-28e0-5653-ba6a-2bcc90f75771/);
  assert.match(scene,/Text: Lighting/);assert.match(scene,/Text: SPECTRAL/);assert.match(scene,/Text: SHARED OPTICS LAB/);
});

test('the runtime keeps every spatial and room binding',()=>{
 const lab=component('625c234f-60df-55cc-b70b-5889745431cf');
 for(const binding of ['glass:','source:','crystalVisual:','raysVisual:','patchVisual:','label:','worldMeshVisual:'])assert.match(lab,new RegExp(binding));
 assert.match(lab,/enableRoomQuery: true/);
});

test('the initial crystal sits inside the comfortable lower-center field of view',()=>{
 assert.match(object('b4aeec98-a772-4f93-8b6d-9d1ef54bf2ba'),/Position: \{x: 0\.000000, y: -22\.20000[01], z: -70\.000000\}/);
});

test('teaching rays stay visually joined while receiver caustics keep room occlusion',()=>{
 assert.match(runtime,/raysVisual\.mainPass\.depthTest=true/);
 assert.match(runtime,/patchVisual\.mainPass\.depthTest=true/);
});

test('crystal rays and projections use one consistent world-space convention',()=>{
 assert.match(crystalShader,/getSurfacePositionWorldSpace\(\)/);
 assert.match(crystalShader,/getMatrixProjectionView\(\)/);
 assert.doesNotMatch(crystalShader,/getMatrixProjectionViewWorld\(\)/);
 assert.doesNotMatch(crystalShader,/getScreenUVCoord\(\)/);
 assert.match(runtime,/depthTest=!this\.stableGlassVisibility/);
 assert.match(runtime,/pass\.twoSided=true/);
 assert.match(component('625c234f-60df-55cc-b70b-5889745431cf'),/stableGlassVisibility: false/);
});

test('world-space buttons accept direct and indirect hands with usable hit targets',()=>{
 assert.match(buttonRuntime,/interaction\.targetingMode=7/);
 assert.match(buttonRuntime,/interaction\.ignoreInteractionPlane=true/);
 assert.match(buttonRuntime,/interaction\.keepHoverOnTrigger=true/);
 assert.match(buttonRuntime,/interaction\.useFilteredPinch=true/);
 for(const id of ['e02e9ce8-3359-42f4-8888-c06d9a46b626','65f4d355-e6c4-4ec6-8c7c-ff3c241050de','fbc69e3c-418a-4aca-89c6-72e47cc03664'])assert.match(scene,new RegExp(`ColliderComponent/${id}>[\\s\\S]*?Size: \\{x: 40\\.000000, y: 20\\.000000, z: 8\\.000000\\}`));
 assert.match(buttonRuntime,/onTriggerStart/);
 assert.match(component('9f340924-fe80-56a9-9fa5-8a0c908c7c63'),/feedbackLabel: !<reference\.Text> 4bfe82f0-5a48-5728-ac15-9397c1fb8886/);
});

test('crystal manipulation is unconstrained in 3D and idle motion uses the iOS curves',()=>{
 const manipulation=component('1359a0d1-e3cf-4b06-9c9b-1d0fc9049aae');
 assert.match(manipulation,/enableTranslation: true/);assert.match(manipulation,/_enableXTranslation: true/);assert.match(manipulation,/_enableYTranslation: true/);assert.match(manipulation,/_enableZTranslation: true/);
 for(const setting of ['control.targetingMode=7','control.ignoreInteractionPlane=true','control.enableInstantDrag=true','control.isScrollable=true','control.acceptableXDirections=true','control.acceptableYDirections=true','control.acceptableZDirections=true','manipulation.enableStretchZ=true','manipulation.enableXTranslation=true','manipulation.enableYTranslation=true','manipulation.enableZTranslation=true'])assert.ok(runtime.includes(setting),setting);
 assert.match(runtime,/new IdleCrystalMotion\(\)/);assert.match(runtime,/offset\[1\]\*100/);assert.match(runtime,/onManipulationStart/);assert.match(runtime,/onManipulationEnd/);
 assert.match(runtime,/this\.idleCinema=frame\.cinema/);assert.match(crystalShader,/cinematicReflection/);assert.match(crystalShader,/lightPeak\.y/);
});

test('preview input is diagnosable and the editor mouse exercises depth',()=>{
 const mouse=component('0015ab95-8697-4aa2-9f60-2ae4f31a7bcb');
 assert.match(mouse,/moveInDepth: true/);assert.match(mouse,/moveInDepthAmount: !<float> 12\.000000/);
 assert.match(runtime,/SIK\.HandInputData\.getHand\('left'\)/);assert.match(runtime,/SIK\.HandInputData\.getHand\('right'\)/);
 assert.match(runtime,/Input editor/);assert.match(runtime,/isPinching\(\)/);
});

test('initial placement commits a real world pose before 3D manipulation',()=>{
 const lab=component('625c234f-60df-55cc-b70b-5889745431cf');
 assert.match(lab,/surfacePlacement: false/);
 assert.match(runtime,/getTargetingInteractors\(\)/);assert.match(runtime,/onTriggerEnd\.add/);
 assert.match(runtime,/if\(target===null\)this\.commitWorldPlacement/);
 assert.match(runtime,/direction\.uniformScale\(75\)/);assert.match(runtime,/setWorldPosition\(position\)/);
 assert.match(runtime,/this\.glass\.enabled=false/);assert.match(runtime,/this\.glass\.enabled=true/);
 assert.match(runtime,/World Query unavailable; free-space placement remains active/);
});
