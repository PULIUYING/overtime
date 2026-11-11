// v3：仅允许管理自己的三种登录状态，不接受其他用户 ID。
import { createClient } from 'npm:@supabase/supabase-js@2';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json'};
Deno.serve(async req=>{
 const reply=(status:number,v:unknown)=>new Response(JSON.stringify(v),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return reply(405,{message:'仅支持 POST'});
 try{
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const token=(req.headers.get('Authorization')||'').replace(/^Bearer /,'');
 const {data:{user},error}=await admin.auth.getUser(token);
 if(error||!user)return reply(401,{message:'请先登录'});
 const {data:profile}=await admin.from('profiles').select('role,owner_id').eq('id',user.id).single();
 if(!profile||profile.role!=='root'||profile.owner_id!==user.id)return reply(403,{message:'仅自己的管理状态可设置登录密码'});
 const body=await req.json();
 if(!['root','editor','viewer'].includes(body.mode)||typeof body.password!=='string'||body.password.length<12||body.password.length>128)return reply(400,{message:'请选择有效状态，密码须为 12–128 位'});
 // 必须再次验证管理密码，避免只凭遗留会话改密码。
 if(typeof body.currentPassword!=='string')return reply(400,{message:'请填写当前管理密码'});
 const verifier=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const verified=await verifier.auth.signInWithPassword({email:user.email!,password:body.currentPassword});
 if(verified.error||!verified.data.session)return reply(403,{message:'当前管理密码错误'});
 await verifier.auth.signOut({scope:'local'});
 const {data:existing}=await admin.from('profiles').select('id').eq('owner_id',user.id).eq('role',body.mode).maybeSingle();
 let target=existing?.id;
 if(target){const {error}=await admin.auth.admin.updateUserById(target,{password:body.password});if(error)return reply(400,{message:error.message});}
 else {
 const alias=`mode-${crypto.randomUUID()}@overtime.invalid`;
 const {data,error}=await admin.auth.admin.createUser({email:alias,password:body.password,email_confirm:true});
 if(error)return reply(400,{message:error.message});target=data.user.id;
 const {error:mapError}=await admin.from('profiles').update({owner_id:user.id,role:body.mode}).eq('id',target);
 if(mapError){await admin.auth.admin.deleteUser(target);return reply(409,{message:'状态初始化冲突，请重试'});}
 }
 const {error:logError}=await admin.from('audit_logs').insert({owner_id:user.id,actor_id:user.id,mode:'root',action:'auth.password_set',entity_id:body.mode,detail:{}});
 if(logError)return reply(503,{message:'密码已更新，但日志写入失败，请检查服务'});
 return reply(200,{ok:true});
 }catch{return reply(500,{message:'密码设置失败，请检查服务配置'});}
});
