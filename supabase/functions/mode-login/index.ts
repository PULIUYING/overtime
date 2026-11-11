import { createClient } from 'npm:@supabase/supabase-js@2';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json'};
Deno.serve(async req=>{
 const reply=(status:number,v:unknown)=>new Response(JSON.stringify(v),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return reply(405,{message:'仅支持 POST'});
 try{
 const body=await req.json();
 if(!['root','editor','viewer'].includes(body.mode)||typeof body.email!=='string'||typeof body.password!=='string'||body.password.length>128)return reply(400,{message:'登录信息无效'});
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:owner}=await admin.from('profiles').select('id').eq('email',body.email.trim().toLowerCase()).eq('role','root').maybeSingle();
 const denied=()=>reply(401,{message:'邮箱、状态或密码错误；请确认该状态已设置密码'});
 if(!owner)return denied();
 const {data:profile}=await admin.from('profiles').select('id,email').eq('owner_id',owner.id).eq('role',body.mode).maybeSingle();
 if(!profile)return denied();
 // Auth 自身执行密码验证和速率限制；管理密钥不参与密码绕过。
 const authClient=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data,error}=await authClient.auth.signInWithPassword({email:profile.email,password:body.password});
 if(error||!data.session)return denied();
 const {error:logError}=await admin.from('audit_logs').insert({owner_id:owner.id,actor_id:profile.id,mode:body.mode,action:'auth.login',detail:{}});
 if(logError){await admin.auth.admin.signOut(data.session.access_token,'local');return reply(503,{message:'登录日志写入失败，请稍后重试'});}
 return reply(200,data.session);
 }catch{return reply(500,{message:'登录服务未就绪，请检查部署'});}
});
