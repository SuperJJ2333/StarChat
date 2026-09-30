export const PAGE_SIZES = Object.freeze([10,20,50]);
export function pageSizeControl(onChange,{label='每页条数'}={}) {
  const select=document.createElement('select');select.className='admin-filter admin-page-size';select.setAttribute('aria-label',label);
  for(const size of PAGE_SIZES){const option=document.createElement('option');option.value=String(size);option.textContent=`${size} 条 / 页`;select.append(option);}
  select.value='10';let committed=10;
  select.commitPageSize=size=>{if(PAGE_SIZES.includes(size)){committed=size;select.value=String(size);}};
  select.addEventListener('change',async()=>{const value=Number(select.value);if(select.disabled||!PAGE_SIZES.includes(value)){select.value=String(committed);return;}const previous=committed;select.disabled=true;try{const result=await onChange(value,previous);if(result===false)select.value=String(previous);else committed=value;}catch{select.value=String(previous);}finally{select.disabled=false;}});
  return select;
}
export function changePageSize(assign,reload){return async(value,previous)=>{assign(value);try{const result=await reload();if(result===false)assign(previous);return result;}catch(error){assign(previous);throw error;}};}
