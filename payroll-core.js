'use strict';
// 纯计算核心。金额逐项四舍五入到分；仅用于居民个人标准工时工资测算。
(function(root){
 const round=n=>Math.round((n+Number.EPSILON)*100)/100;
 const payMultipliers={workday:1.5,rest:2,statutory:3,compensated:0};
 function taxFor(taxable){const x=Math.max(0,taxable);const bands=[[36000,.03,0],[144000,.1,2520],[300000,.2,16920],[420000,.25,31920],[660000,.3,52920],[960000,.35,85920],[Infinity,.45,181920]];const b=bands.find(b=>x<=b[0]);return round(x*b[1]-b[2]);}
 function compute(rows,s){
 const number=k=>{const n=Number(s[k]??0);if(!Number.isFinite(n)||n<0)throw Error('参数必须为非负数：'+k);return n;};
 if(rows.some(r=>!Number.isFinite(r.hours)||r.hours<0||r.hours>24))throw Error('记录时长无效');
 const totalHours=rows.reduce((a,r)=>a+r.hours,0),pending=rows.filter(r=>!Object.hasOwn(payMultipliers,r.pay_kind));
 const base=number('overtimeBase'),hourly=base/(21.75*8);
 const overtime=round(rows.reduce((a,r)=>a+r.hours*(payMultipliers[r.pay_kind]??0)*hourly,0));
 const gross=round(number('salary')+number('allowance')+overtime-number('absence'));
 if(gross<0)throw Error('税前扣款超过应发工资');
 const contributions={};for(const k of ['pension','medical','unemployment','injury','maternity','fund']){const rate=number(k+'Rate');if(rate>100)throw Error('缴费比例不可超过 100%');contributions[k]=round(number(k+'Base')*rate/100+number(k+'Fixed'));}
 const insurance=round(Object.entries(contributions).filter(([k])=>k!=='fund').reduce((a,[,v])=>a+v,0));
 const fund=contributions.fund,totalContribution=round(insurance+fund);
 const months=number('employedMonths');if(!Number.isInteger(months)||months<1||months>12)throw Error('本年度任职月数必须为 1–12');
 const deductible=Math.min(totalContribution,number('deductibleContribution'));
 const taxable=Math.max(0,round(number('priorGross')+gross-number('priorExempt')-number('exempt')-5000*months-number('priorContributions')-deductible-number('priorSpecial')-number('special')-number('priorOther')-number('otherDeduction')));
 const accrued=taxFor(taxable),tax=round(Math.max(0,accrued-number('taxRelief')-number('priorTax')));
 const net=round(gross-totalContribution-tax-number('afterTaxDeduction'));
 return {totalHours,ratio:number('standardHours')>0?totalHours/number('standardHours')*100:null,overTimeHourly:hourly,overtime,pending:pending.length,gross,insurance,fund,totalContribution,contributions,taxable,accrued,tax,net,deductible};
 }
 root.Payroll={compute,taxFor,round};
})(typeof globalThis!=='undefined'?globalThis:this);
