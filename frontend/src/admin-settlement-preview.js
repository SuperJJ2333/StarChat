const scale=1000000n;
function micros(value){
  if(typeof value!=='string'||!/^\d{1,24}(?:\.\d{1,6})?$/.test(value))return null;
  const [whole,fraction='']=value.split('.');return BigInt(whole)*scale+BigInt(fraction.padEnd(6,'0'));
}
const format=value=>`${value/scale}.${String(value%scale).padStart(6,'0')}`;
export function previewWithdrawal(fundingAmount,finalRate){
  const amount=micros(fundingAmount),rate=micros(finalRate);
  if(amount===null||amount<=0n||amount%10000n!==0n||rate===null||rate<=0n||rate>=1000n*scale)return null;
  return format((2n*amount*scale+rate)/(2n*rate));
}
export function adjustReferenceRate(referenceRate,percent){
  const rate=micros(referenceRate);
  if(rate===null||rate<=0n||![95,99,100,101,105].includes(percent))return null;
  const adjusted=(rate*BigInt(percent)+50n)/100n;
  return adjusted>0n&&adjusted<1000n*scale?format(adjusted):null;
}
