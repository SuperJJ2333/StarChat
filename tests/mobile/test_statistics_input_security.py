"""Execute the shipped statistics renderer with hostile fresh/restored input."""
import json
import subprocess
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[2]

@pytest.mark.parametrize("text,money", [
    ("01 <img src=x onerror=alert(1)>", "1"),
    ("<svg onload=alert(1)>", "<img src=x onerror=alert(2)>"),
    ("&lt;img src=x onerror=alert(1)&gt;", "2"),
    ("01 02 鼠", "10"),
])
def test_statistics_last_input_is_rendered_as_text(text, money):
    program = r"""
const fs=require('fs'),vm=require('vm');
const source=fs.readFileSync('apps/mobile_flutter/assets/html/statistics_tools_combined_v2.html','utf8');
const start=source.indexOf('    function renderLastTip(');
const end=source.indexOf('    function renderNumPanel(',start);
const htmlWrites=[];
class Element {
  constructor(){this.children=[];this.textContent='';}
  set innerHTML(value){htmlWrites.push(value);}
  replaceChildren(...nodes){this.children=nodes;}
  append(...nodes){this.children.push(...nodes);}
}
const element=new Element();
const document={getElementById:()=>element,createElement:()=>new Element(),createTextNode:text=>({textContent:text})};
const lastInput=JSON.parse(process.argv[1]);
vm.runInNewContext(source.slice(start,end)+';renderLastTip();',{document,lastInput});
function textOf(node){return typeof node==='string'?node:node.textContent+((node.children||[]).map(textOf).join(''));}
console.log(JSON.stringify({htmlWrites,text:textOf(element)}));
"""
    result = subprocess.run(
        ["node", "-e", program, json.dumps({"text":text,"money":money,"opt":"add"})],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", check=True,
    )
    rendered = json.loads(result.stdout)
    assert rendered["htmlWrites"] == [], "User-controlled state must not enter innerHTML"
    assert rendered["text"] == f"最后操作：✅ 加金额｜内容：{text}｜金额：{money}元"

def test_restored_cache_drops_executable_fields_without_losing_valid_totals():
    program = r"""
const fs=require('fs'),vm=require('vm');
const source=fs.readFileSync('apps/mobile_flutter/assets/html/statistics_tools_combined_v2.html','utf8');
const start=source.indexOf('    window.t1_restoreState = function(s)');
const end=source.indexOf('\n})();',start);
const ctx={window:{},numCount:{},recordArr:[],lastInput:{},pageNow:1,selectedSet:new Set(),
 MAX_SAVE_NUM:10000,MAX_MONEY:99999,PAGE_SIZE:100,pad2:n=>String(n).padStart(2,'0'),
 initNumCount(){for(let i=1;i<=49;i++)ctx.numCount[String(i).padStart(2,'0')]=0;},
 renderLastTip(){},renderAll(){}};
vm.createContext(ctx);vm.runInContext(source.slice(start,end),ctx);
ctx.window.t1_restoreState({
 numCount:{'01':'<img src=x onerror=alert(1)>','02':123,'03':Infinity,"04' onfocus='alert(1)":3},
 records:[{type:'加',list:[{num:2,amount:5}]},{type:'加',list:[{num:1,amount:'<svg onload=alert(1)>'}]}],
 pageNow:'1);alert(1)//',selected:['02',"01' onclick='alert(1)"],
 lastInput:{text:'plain',money:'5',opt:'add'}
});
console.log(JSON.stringify({counts:ctx.numCount,records:ctx.recordArr,page:ctx.pageNow,selected:[...ctx.selectedSet]}));
"""
    data = json.loads(subprocess.run(["node","-e",program],cwd=ROOT,capture_output=True,
                                    text=True,encoding="utf-8",check=True).stdout)
    assert len(data["counts"]) == 49
    assert data["counts"]["01"] == 0
    assert data["counts"]["02"] == 123
    assert data["counts"]["03"] == 0
    assert len(data["records"]) == 1
    assert data["records"][0]["list"] == [{"num":2,"amount":5}]
    assert data["page"] == 1
    assert data["selected"] == ["02"]
